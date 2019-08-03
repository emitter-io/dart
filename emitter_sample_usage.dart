String secretKey = "J31n6RIj3bgV2uUihswQ5CsjbJJ98yU2";
Emitter _emitter = new Emitter();
_emitter.onMessage((EmitterMessage message) {
  print("New message: ${message.channel} -> ${message.asString()}");
});
_emitter.onPresence((obj) {
  print("OnPresence:");
  print(obj);
});
await _emitter.connect(host: "my.server.com", port: 8080, secure: false);
String _key = await _emitter.keygen(secretKey, "mychannel/#/", "rwslpe", 0);
print("Key generated:" + _key);
print("Subscribing to mychannel/hello presence");
_emitter.subscribePresence(_key, "mychannel/");
print("Subscribing to mychannel/hello");
_emitter.subscribe(_key, "mychannel/hello", handler: (message) {
  print("Inline message handler:" + message.channel + " => " + message.asString());
});
print("Publishing message to mychannel");
_emitter.publish(_key, "mychannel/hello", "Hello from Flutter Emitter");
var pr = await _emitter.getPresence(_key, "mychannel/hello");
print(pr);
var me = await _emitter.getMe();
print(me);
var linkResult = await _emitter.link(_key, "mychannel/privatelink/", "rq", true, true);
print(linkResult);
_emitter.publishWithLink("rq", "Hello");
