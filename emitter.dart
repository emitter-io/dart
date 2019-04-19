import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_data.dart';
import 'dart:convert';

typedef EmitterCallback = void Function(Emitter emitter);
typedef EmitterSubscribeCallback = void Function(String topic);
typedef EmitterKeygenCallback = void Function(dynamic object);
typedef EmitterPresenceCallback = void Function(dynamic object);
typedef EmitterMeCallback = void Function(dynamic object);
typedef EmitterMessageCallback = void Function(EmitterMessage message);

class Emitter {
  MqttClient _mqtt;

  EmitterCallback onConnect;
  EmitterCallback onDisconnect;
  EmitterSubscribeCallback onSubscribed;
  EmitterSubscribeCallback onUnsubscribed;
  EmitterSubscribeCallback onSubscribeFail;
  EmitterKeygenCallback onKeygen;
  EmitterPresenceCallback onPresence;
  EmitterMeCallback onMe;
  EmitterMessageCallback onMessage;

  Future<bool> connect({
    bool secure = false,
    String host = "api.emitter.io",
    int port = 8080,
    int keepalive = 60,
    bool logging = false,
  }) async {
    String brokerUrl = (secure ? "wss://" : "ws://") + host;
    _mqtt = new MqttClient(brokerUrl, "");
    _mqtt.port = port;
    _mqtt.useWebSocket = true;
    _mqtt.useAlternateWebSocketImplementation = false;
    _mqtt.logging(on: logging);
    _mqtt.keepAlivePeriod = keepalive;
    _mqtt.onDisconnected = _onDisconnected;
    _mqtt.onConnected = _onConnected;
    _mqtt.onSubscribed = _onSubscribed;
    _mqtt.onUnsubscribed = _onUnsubscribed;
    _mqtt.onSubscribeFail = _onSubscribeFail;
    _mqtt.pongCallback = _pong;

    final MqttConnectMessage connMess = MqttConnectMessage()
        .keepAliveFor(keepalive)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _mqtt.connectionMessage = connMess;

    try {
      await _mqtt.connect();
    } on Exception catch (e) {
      print('EMITTER::client exception - $e');
      _mqtt.disconnect();
      return false;
    }

    /// Check we are connected
    if (_mqtt.connectionStatus.state == MqttConnectionState.connected) {
      print('EMITTER::Mosquitto client connected');
    } else {
      print(
          'EMITTER::ERROR Mosquitto client connection failed - disconnecting, state is ${_mqtt.connectionStatus.state}');
      _mqtt.disconnect();
      return false;
    }

    _mqtt.updates.listen(_onMessage);

    return true;
  }

  /*
  * Publishes a message to the currently opened endpoint.
  */
  publish(String key, String channel, String message,
      {bool me = true, int ttl = 0}) {
    var options = new Map<String, String>();
    // The default server's behavior when 'me' is absent, is to send the publisher its own messages.
    // To avoid any ambiguity, this parameter is always set here.
    if (me) {
      options["me"] = "1";
    } else {
      options["me"] = "0";
    }
    options["ttl"] = ttl.toString();
    var topic = _formatChannel(key, channel, options);
    _mqtt.publishMessage(topic, MqttQos.atLeastOnce, _payload(message));
    return this;
  }

  /*
  * Publishes a message through a link.
  */
  publishWithLink(String link, String message) {
    _mqtt.publishMessage(link, MqttQos.atLeastOnce, _payload(message));
  }

  /*
  * Subscribes to a particular channel.
  */
  subscribe(String key, String channel, {int last = 0}) {
    var options = new Map<String, String>();
    if (last > 0) options["last"] = last.toString();
    var topic = _formatChannel(key, channel, options);
    _mqtt.subscribe(topic, MqttQos.atLeastOnce);
    return this;
  }

  /*
  * Create a link to a particular channel.
  */
  link(String key, String channel, String name, bool private, bool subscribe,
      {bool me = true, int ttl = 0}) {
    var options = new Map<String, String>();
    // The default server's behavior when 'me' is absent, is to send the publisher its own messages.
    // To avoid any ambiguity, this parameter is always set here.
    if (me) {
      options["me"] = "1";
    } else {
      options["me"] = "0";
    }
    options["ttl"] = ttl.toString();

    String formattedChannel = _formatChannel(null, channel, options);
    var request = {
      "key": key,
      "channel": formattedChannel,
      "name": name,
      "private": private,
      "subscribe": subscribe
    };
    _mqtt.publishMessage(
        "emitter/link/", MqttQos.atLeastOnce, _payload(jsonEncode(request)));
    return this;
  }

  /*
  * Unsubscribes from a particular channel.
  */
  unsubscribe(String key, String channel) {
    var topic = _formatChannel(key, channel, null);
    _mqtt.unsubscribe(topic);
    return this;
  }

  /*
  * Sends a key generation request to the server.
  * type is the type of the key to generate. Possible options include r for read-only, w for write-only, 
  * p for presence only and rw for read-write keys 
  * (In addition to rw, you can use any combination of r, w and p for key generation)
  * ttl is the time-to-live of the key, in seconds.
  */
  keygen(String key, String channel, String type, int ttl) {
    var request = {"key": key, "channel": channel, "type": type, "ttl": ttl};
    _mqtt.publishMessage(
        "emitter/keygen/", MqttQos.atLeastOnce, _payload(jsonEncode(request)));
    return this;
  }

  /*
  * Sends a presence request to the server.
  * status: Whether a full status should be sent back in the response.
  * changes: Whether we should subscribe this client to presence notification events.
  */
  presence(String key, String channel, bool status, bool changes) {
    var request = {
      "key": key,
      "channel": channel,
      "status": status,
      "changes": changes
    };
    _mqtt.publishMessage("emitter/presence/", MqttQos.atLeastOnce,
        _payload(jsonEncode(request)));
    return this;
  }

  /*
  * Request information about the connection to the server.
  */
  me() {
    _mqtt.publishMessage("emitter/me/", MqttQos.atLeastOnce, _payload(""));
  }

  _formatChannel(String key, String channel, Map<String, String> options) {
    var formatted = channel;
    // Prefix with the key if any
    if (key != null && key.length > 0)
      formatted = key.endsWith("/") ? key + channel : key + "/" + channel;
    // Add trailing slash
    if (!formatted.endsWith("/")) formatted += "/";
    // Add options
    if (options != null && options.length > 0) {
      formatted += "?";
      options.forEach((key, value) => {formatted += key + "=" + value + "&"});
    }
    if (formatted.endsWith("&"))
      formatted = formatted.substring(0, formatted.length - 1);
    // We're done compiling the channel name
    return formatted;
  }

  Uint8Buffer _payload(String message) {
    final MqttClientPayloadBuilder builder = MqttClientPayloadBuilder();
    builder.addString(message);
    return builder.payload;
  }

  _onDisconnected() {
    print('EMITTER::Disconnected');
    if (onDisconnect != null) onDisconnect(this);
  }

  _onConnected() {
    print('EMITTER::Connected');
    if (onConnect != null) onConnect(this);
  }

  _onSubscribed(String topic) {
    print('EMITTER::Subscription confirmed for topic $topic');
    if (onSubscribed != null) onSubscribed(topic);
  }

  _onUnsubscribed(String topic) {
    print('EMITTER::Unsubscription confirmed for topic $topic');
    if (onUnsubscribed != null) onUnsubscribed(topic);
  }

  _onSubscribeFail(String topic) {
    print('EMITTER::Subscription failed for topic $topic');
    if (onSubscribeFail != null) onSubscribeFail(topic);
  }

  _pong() {
    print('EMITTER::Pong');
  }

  _onMessage(List<MqttReceivedMessage<MqttMessage>> c) {
    final MqttPublishMessage msg = c[0].payload;
    final String topic = c[0].topic;
    var message = new EmitterMessage(topic, msg.payload.message);
    print('EMITTER::$topic -> ${message.asString()}');
    if (topic.startsWith("emitter/keygen")) {
      if (onKeygen != null) onKeygen(message.asObject());
    } else if (topic.startsWith("emitter/presence")) {
      if (onPresence != null) onPresence(message.asObject());
    } else if (topic.startsWith("emitter/me")) {
      if (onMe != null) onMe(message.asObject());
    } else {
      if (onMessage != null) onMessage(message);
    }
  }
}

class EmitterMessage {
  String channel;
  Uint8Buffer binary;

  EmitterMessage(String topic, Uint8Buffer payload) {
    channel = topic;
    binary = payload;
  }

  String asString() {
    return MqttPublishPayload.bytesToStringAsString(binary);
  }

  dynamic asObject() {
    dynamic object; 
    try {
      object = jsonDecode(asString());
    } catch (err) {}
    return object;
  }

}
