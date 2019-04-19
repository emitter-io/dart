String key = "8JomQ2vFhHoU_DfGdBKfZvChXXUECdHG";
String secretKey = "J31n6RIj3bgV2uUihswQ5CsjbJJ98yU2";
_emitter = new Emitter();
_emitter.onMessage = (EmitterMessage message) {
  print("New message: ${message.channel} -> ${message.asString()}");
};
_emitter.onKeygen = (obj) {
  print("New key: ${obj["key"]} for channel ${obj["channel"]}");
};
_emitter.onPresence = (obj) {
  if (obj["event"] == "subscribe") {
    print("${obj["who"]["id"]} subscribed to channel ${obj["channel"]}");
  }      
  if (obj["event"] == "unsubscribe") {
    print("${obj["who"]["id"]} unsubscribed from channel ${obj["channel"]}");
  }      
};
await _emitter.connect();
print("CONNECTED");
_emitter.me();
_emitter.subscribe(key, "mychannel");
_emitter.publish(key, "mychannel", "Hello from Flutter Emitter");
_emitter.keygen(secretKey, "mychannel/hello/", "rw", 0);
_emitter.presence(key, "mychannel/hello", true, true);
_emitter.subscribe(key, "mychannel/hello");
