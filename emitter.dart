import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_data.dart';
import 'dart:convert';
import 'dart:async';

typedef EmitterCallback = void Function(Emitter emitter);
typedef EmitterSubscribeCallback = void Function(String topic);
typedef EmitterPresenceCallback = void Function(dynamic object);
typedef EmitterMessageCallback = void Function(EmitterMessage message);

class Emitter {
  MqttClient _mqtt;
  String _rpcChannel = "";
  String _rpcKey = "";
  String _myId = "";
  int _rpcId = 0;
  ReverseTrie _trie = new ReverseTrie(level: -1);
  bool _logging = false;

  var _onConnectHandlers = <EmitterCallback>[];
  void onConnect(EmitterCallback handler) => _onConnectHandlers.add(handler);
  var _onDisconnectHandlers = <EmitterCallback>[];
  void onDisconnect(EmitterCallback handler) =>
      _onDisconnectHandlers.add(handler);
  var _onSubscribedHandlers = <EmitterSubscribeCallback>[];
  void onSubscribed(EmitterSubscribeCallback handler) =>
      _onSubscribedHandlers.add(handler);
  var _onUnsubscribedHandlers = <EmitterSubscribeCallback>[];
  void onUnsubscribed(EmitterSubscribeCallback handler) =>
      _onUnsubscribedHandlers.add(handler);
  var _onSubscribeFailHandlers = <EmitterSubscribeCallback>[];
  void onSubscribeFail(EmitterSubscribeCallback handler) =>
      _onSubscribeFailHandlers.add(handler);
  var _onPresenceHandlers = <EmitterPresenceCallback>[];
  void onPresence(EmitterPresenceCallback handler) =>
      _onPresenceHandlers.add(handler);
  var _onMessageHandlers = <EmitterMessageCallback>[];
  void onMessage(EmitterMessageCallback handler) =>
      _onMessageHandlers.add(handler);

  Map<int, Completer> _completers = new Map<int, Completer>();
  Map<int, Completer> _rpcCompleters = new Map<int, Completer>();

  Future<bool> connect(
      {bool secure = false,
      String host = "api.emitter.io",
      int port = 8080,
      int keepalive = 60,
      bool logging = false,
      bool useWebSocket = false}) async {
    String brokerUrl =
        useWebSocket ? (secure ? "wss://" : "ws://") + host : host;
    _mqtt = new MqttClient(brokerUrl, "");
    _mqtt.port = port;
    _mqtt.secure = useWebSocket ? false : secure;
    _mqtt.useWebSocket = useWebSocket;
    _mqtt.useAlternateWebSocketImplementation = false;
    _mqtt.logging(on: logging);
    _mqtt.keepAlivePeriod = keepalive;
    _mqtt.onDisconnected = _onDisconnected;
    _mqtt.onConnected = _onConnected;
    _mqtt.onSubscribed = _onSubscribed;
    _mqtt.onUnsubscribed = _onUnsubscribed;
    _mqtt.onSubscribeFail = _onSubscribeFail;
    _mqtt.pongCallback = _pong;
    _logging = logging;

    final MqttConnectMessage connMess = MqttConnectMessage()
        .keepAliveFor(keepalive)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _mqtt.connectionMessage = connMess;

    try {
      await _mqtt.connect();
    } on Exception catch (e) {
      _log('EMITTER::client exception - $e');
      _mqtt.disconnect();
      return false;
    }

    /// Check we are connected
    if (_mqtt.connectionStatus.state == MqttConnectionState.connected) {
      _log('EMITTER::Mosquitto client connected');
    } else {
      _log(
          'EMITTER::ERROR Mosquitto client connection failed - disconnecting, state is ${_mqtt.connectionStatus.state}');
      _mqtt.disconnect();
      return false;
    }

    _mqtt.updates.listen(_onMessage);
    var me = await getMe();
    _myId = me["id"];
    return true;
  }

  /*
  * Publishes a message to the currently opened endpoint.
  */
  int publish(String key, String channel, String message,
      {bool me = true,
      int ttl = 0,
      MqttQos qos = MqttQos.atLeastOnce,
      bool retain = false}) {
    var options = new Map<String, String>();
    if (!me) options["me"] = "0";
    if (ttl > 0) options["ttl"] = ttl.toString();
    var topic = _formatChannel(key, channel, options);
    return _mqtt.publishMessage(topic, qos, _payload(message), retain: retain);
  }

  /*
  * Publishes a message through a link.
  */
  int publishWithLink(String link, String message) {
    return _mqtt.publishMessage(link, MqttQos.atLeastOnce, _payload(message));
  }

  /*
  * Subscribes to a particular channel.
  */
  Subscription subscribe(String key, String channel, {int last = 0, EmitterMessageCallback handler}) {
    if (handler != null)
      this._trie.registerHandler(channel, handler);

    var options = new Map<String, String>();
    if (last > 0) options["last"] = last.toString();
    var topic = _formatChannel(key, channel, options);
    return _mqtt.subscribe(topic, MqttQos.atLeastOnce);
  }

  /*
  * Create a link to a particular channel.
  */
  Future<dynamic> link(
      String key, String channel, String name, bool private, bool subscribe,
      {bool me = true, int ttl = 0, int timeout = 5000}) async {
    var options = new Map<String, String>();
    if (!me) options["me"] = "0";
    if (ttl > 0) options["ttl"] = ttl.toString();
    String formattedChannel = _formatChannel(null, channel, options);
    var request = {
      "key": key,
      "channel": formattedChannel,
      "name": name,
      "private": private,
      "subscribe": subscribe
    };
    var response = await _executeAsync("emitter/link/", jsonEncode(request),
        timeout: timeout);
    return response;
  }

  /*
  * Unsubscribes from a particular channel.
  */
  void unsubscribe(String key, String channel) {
    this._trie.unRegisterHandler(channel);

    var topic = _formatChannel(key, channel, null);
    _mqtt.unsubscribe(topic);
  }

  /*
  * Sends a key generation request to the server.
  * type is the type of the key to generate. 
  * r = Read, w = Write, s = Store, l = Load, p = Presence, e = Extending for private sub-channels
  * You can use any combination like "rw", "rwe" etc.
  * ttl is the time-to-live of the key, in seconds.
  */
  Future<String> keygen(String key, String channel, String type, int ttl,
      {int timeout = 5000}) async {
    var request = {"key": key, "channel": channel, "type": type, "ttl": ttl};
    var response = await _executeAsync("emitter/keygen/", jsonEncode(request),
        timeout: timeout);
    if (response != null) {
      return response["key"];
    }
    return "";
  }

  /*
  * Subcribes to presence of a channel
  */
  int subscribePresence(String key, String channel) {
    var request = {
      "key": key,
      "channel": channel,
      "status": false,
      "changes": true
    };
    return _mqtt.publishMessage("emitter/presence/", MqttQos.atLeastOnce,
        _payload(jsonEncode(request)));
  }

  /*
  * Gets the presence of a channel
  */
  Future<dynamic> getPresence(String key, String channel,
      {int timeout = 5000}) async {
    var request = {
      "key": key,
      "channel": channel,
      "status": true,
      "changes": false
    };
    var response = await _executeAsync("emitter/presence/", jsonEncode(request),
        timeout: timeout);
    return response;
  }

  /*
  * Request information about the connection to the server.
  */
  Future<dynamic> getMe({int timeout = 5000}) async {
    var response = await _executeAsync("emitter/me/", "", timeout: timeout);
    return response;
  }

  initRPC(String channel, String key) {
    if (!channel.endsWith("/")) channel += "/";
    _rpcChannel = channel;
    _rpcKey = key;
    subscribe(_rpcKey, _rpcChannel);
  }

  Future<dynamic> rpc(dynamic payload, {int timeout = 5000}) {
    var id = ++_rpcId;
    Completer c = new Completer<dynamic>();
    _rpcCompleters[id] = c;
    var channel = _rpcChannel + _myId + "/" + id.toString();
    publish(_rpcKey, channel, jsonEncode(payload), me: false);
    new Timer(new Duration(milliseconds: timeout), () {
      _rpcCompleters.remove(id);
      if (!c.isCompleted) c.completeError("rpc timeout");
    });
    return c.future;
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
      options.forEach((key, value) {
        formatted += key + "=" + value + "&";
      });
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

  Future<dynamic> _executeAsync(String request, String payload,
      {int timeout = 5000}) {
    Completer c = new Completer<dynamic>();
    int id =
        _mqtt.publishMessage(request, MqttQos.atLeastOnce, _payload(payload));
    _completers[id] = c;
    new Timer(new Duration(milliseconds: timeout), () {
      _completers.remove(id);
      if (!c.isCompleted) c.completeError("$request timeout");
    });
    return c.future;
  }

  _onDisconnected() {
    _log('EMITTER::Disconnected');
    _onDisconnectHandlers.forEach((h) => h(this));
    //if (onDisconnect != null) onDisconnect(this);
  }

  _onConnected() {
    _log('EMITTER::Connected');
    _onConnectHandlers.forEach((h) => h(this));
    //if (onConnect != null) onConnect(this);
  }

  _onSubscribed(String topic) {
    _log('EMITTER::Subscription confirmed for topic $topic');
    _onSubscribedHandlers.forEach((h) => h(topic));
    //if (onSubscribed != null) onSubscribed(topic);
  }

  _onUnsubscribed(String topic) {
    _log('EMITTER::Unsubscription confirmed for topic $topic');
    _onUnsubscribedHandlers.forEach((h) => h(topic));
    //if (onUnsubscribed != null) onUnsubscribed(topic);
  }

  _onSubscribeFail(String topic) {
    _log('EMITTER::Subscription failed for topic $topic');
    _onSubscribeFailHandlers.forEach((h) => h(topic));
    //if (onSubscribeFail != null) onSubscribeFail(topic);
  }

  _pong() {
    _log('EMITTER::Pong');
  }

  _log(Object message) {
    if (_logging) print(message);
  }

  bool _checkRPCResult(EmitterMessage message) {
    var channel = message.channel.substring(0, message.channel.length - 1);
    var id = int.parse(channel.substring(channel.lastIndexOf("/") + 1));
    Completer c = _rpcCompleters[id];
    if (c != null) {
      _rpcCompleters.remove(id);
      c.complete(message.asObject());
      return true;
    }
    return false;
  }

  bool _checkRequestResult(EmitterMessage message) {
    var obj = message.asObject();
    if (obj["req"] != null) {
      Completer c = _completers[obj["req"]];
      if (c != null) {
        _completers.remove(obj["req"]);
        c.complete(obj);
        return true;
      }
    }
    return false;
  }

  _onMessage(List<MqttReceivedMessage<MqttMessage>> c) {
    final MqttPublishMessage msg = c[0].payload;
    final String topic = c[0].topic;
    var message = new EmitterMessage(topic, msg.payload.message);
    _log('EMITTER::$topic -> ${message.asString()}');
    if (topic.startsWith("emitter/presence")) {
      if (!_checkRequestResult(message))
        _onPresenceHandlers.forEach((h) => h(message.asObject()));
    } else if (topic.startsWith("emitter/keygen") ||
        topic.startsWith("emitter/link") ||
        topic.startsWith("emitter/me")) {
      _checkRequestResult(message);
    } else {
      bool callMessageHandler = true;
      if (_rpcChannel != "" && topic.startsWith(_rpcChannel)) {
        callMessageHandler = !_checkRPCResult(message);
      }
      if (callMessageHandler) {
        _onMessageHandlers.forEach((h) => h(message));
        this._trie.match(message.channel).forEach((h) => h(message));
      }
    }
  }
}

class EmitterMessage {
  String channel;
  Uint8Buffer binary;
  String _string;
  dynamic _object;

  EmitterMessage(String topic, Uint8Buffer payload) {
    channel = topic;
    binary = payload;
  }

  String asString() {
    if (_string == null) {
      _string = MqttPublishPayload.bytesToStringAsString(binary);
    }
    return _string;
  }

  dynamic asObject() {
    if (_object == null) {
      try {
        _object = jsonDecode(asString());
      } catch (err) {}
    }
    return _object;
  }
}

class ReverseTrie {
  Map<String, ReverseTrie> children;
  int level;
  EmitterMessageCallback value;

  ReverseTrie({int level = 0}) {
    this.children = new Map<String, ReverseTrie>();
    this.level = level;
    this.value = null;
  }

  registerHandler(String channel, EmitterMessageCallback value) {
    this._setValue(this._createKey(channel), 0, value);    
  }

  unRegisterHandler(String channel) {
    this._tryRemove(this._createKey(channel), 0);       
  }

  List<EmitterMessageCallback> match(String channel)  {
    var query = this._createKey(channel);
    var result =  this._recurMatch(query, 0, this.children);
    return result;
  }

  _setValue(List<String> key, int position, EmitterMessageCallback value) {
    if (position == key.length)
    {
      this.value = value;
      return this.value;
    }

    ReverseTrie child;
    if (this.children[key[position]] != null) {
      child = this.children[key[position]];
    } else {
      child = new ReverseTrie(level: position);
      this.children[key[position]] = child;
    }           
    return child._setValue(key, position + 1, value);
  }

  List<String> _createKey(String channel) {
    return channel.replaceAll(new RegExp("^[/]+"), "").replaceAll(new RegExp("[/]+\$"), "").split("/");
  }

  bool _tryRemove(List<String> key, int position) {
    if (position == key.length)
    {
      if (this.value == null)
          return false;
      this.value = null;
      return true;
    }

    // Remove from the child
    ReverseTrie child = this.children[key[position]];
    if (child != null)
      return child._tryRemove(key, position + 1);

    this.value = null;
    return false;
  }

  List<EmitterMessageCallback> _recurMatch(List<String> query, int posInQuery, Map<String, ReverseTrie> children) {
    List<EmitterMessageCallback> matches = [];
    if (posInQuery == query.length)
      return matches;
    ReverseTrie childNode = children["+"];
    if (childNode != null) {
      if (childNode.value != null)
        matches.add(childNode.value);
      matches.addAll(this._recurMatch(query, posInQuery + 1, childNode.children));
    }
    childNode = children[query[posInQuery]];
    if (childNode != null) {
      if (childNode.value != null)
        matches.add(childNode.value);
      matches.addAll(this._recurMatch(query, posInQuery + 1, childNode.children));
    }
    return matches;
  }

}