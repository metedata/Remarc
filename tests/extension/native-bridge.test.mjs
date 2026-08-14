import assert from "node:assert/strict";
import test from "node:test";

import {
  NATIVE_KEEPALIVE_INTERVAL_MS,
  NativeBridge,
  NativeBridgeState,
} from "../../extension/native-bridge.mjs";

const URL = "ws://127.0.0.1:9274";

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances = [];
  static constructorError = null;

  static reset() {
    FakeWebSocket.instances = [];
    FakeWebSocket.constructorError = null;
  }

  constructor(url) {
    if (FakeWebSocket.constructorError) throw FakeWebSocket.constructorError;
    this.url = url;
    this.readyState = FakeWebSocket.CONNECTING;
    this.sent = [];
    this.closeCalls = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
    FakeWebSocket.instances.push(this);
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.({ target: this });
  }

  send(payload) {
    if (this.readyState !== FakeWebSocket.OPEN) {
      throw new Error("socket is not open");
    }
    this.sent.push(payload);
  }

  close() {
    this.closeCalls += 1;
    this.readyState = FakeWebSocket.CLOSING;
  }

  emitMessage(data) {
    this.onmessage?.({ data, target: this });
  }

  emitError() {
    this.onerror?.({ target: this });
  }

  emitClose() {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.({ target: this });
  }
}

function makeTimers() {
  let nextID = 1;
  const intervals = new Map();
  const cleared = [];

  return {
    intervals,
    cleared,
    setIntervalFn(callback, milliseconds) {
      const id = nextID++;
      intervals.set(id, { callback, milliseconds });
      return id;
    },
    clearIntervalFn(id) {
      cleared.push(id);
      intervals.delete(id);
    },
    tickAll() {
      for (const { callback } of [...intervals.values()]) callback();
    },
  };
}

function makeHarness(overrides = {}) {
  FakeWebSocket.reset();
  const timers = makeTimers();
  const states = [];
  const messages = [];
  let reconnectRequests = 0;

  const bridge = new NativeBridge({
    url: URL,
    WebSocketImpl: FakeWebSocket,
    setIntervalFn: timers.setIntervalFn,
    clearIntervalFn: timers.clearIntervalFn,
    onStateChange: (state, previous) => states.push([previous, state]),
    onMessage: (message) => messages.push(message),
    onReconnectNeeded: () => {
      reconnectRequests += 1;
    },
    ...overrides,
  });

  return {
    bridge,
    timers,
    states,
    messages,
    reconnectRequests: () => reconnectRequests,
  };
}

test("connect is idempotent while connecting and connected", () => {
  const { bridge, states } = makeHarness();

  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(bridge.connect(), true);
  assert.equal(bridge.connect(), false);
  assert.equal(FakeWebSocket.instances.length, 1);
  assert.equal(FakeWebSocket.instances[0].url, URL);

  FakeWebSocket.instances[0].open();
  assert.equal(bridge.connect(), false);
  assert.equal(FakeWebSocket.instances.length, 1);
  assert.deepEqual(states, [
    [NativeBridgeState.DISCONNECTED, NativeBridgeState.CONNECTING],
    [NativeBridgeState.CONNECTING, NativeBridgeState.CONNECTED],
  ]);
});

test("send acknowledges delivery only while the current socket is OPEN", () => {
  const { bridge } = makeHarness();
  const envelope = { type: "selectionContext", data: { pageUrl: "https://example.com" } };

  assert.equal(bridge.send(envelope), false);
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  assert.equal(bridge.send(envelope), false);

  socket.open();
  assert.equal(bridge.send(envelope), true);
  assert.deepEqual(JSON.parse(socket.sent[0]), envelope);

  socket.emitClose();
  assert.equal(bridge.send(envelope), false);
});

test("send disconnects a current non-OPEN socket and ignores its stale close", () => {
  const { bridge, reconnectRequests, timers } = makeHarness();
  bridge.connect();
  const first = FakeWebSocket.instances[0];
  first.open();
  first.readyState = FakeWebSocket.CLOSING;

  assert.equal(bridge.send({ type: "tabActivity", data: {} }), false);
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(first.closeCalls, 1);
  assert.equal(timers.intervals.size, 0);
  assert.equal(reconnectRequests(), 1);

  assert.equal(bridge.retryNow(), true);
  const replacement = FakeWebSocket.instances[1];
  replacement.open();
  first.emitClose();

  assert.equal(bridge.state, NativeBridgeState.CONNECTED);
  assert.equal(reconnectRequests(), 1);
  assert.equal(bridge.send({ type: "tabActivity", data: {} }), true);
  assert.equal(replacement.sent.length, 1);
});

test("open starts one 20-second JSON keepalive and close clears it", () => {
  const { bridge, timers } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  assert.equal(timers.intervals.size, 1);
  const [{ milliseconds }] = timers.intervals.values();
  assert.equal(milliseconds, NATIVE_KEEPALIVE_INTERVAL_MS);

  timers.tickAll();
  assert.deepEqual(JSON.parse(socket.sent.at(-1)), {
    type: "tabActivity",
    data: { reason: "keepalive" },
  });

  socket.emitClose();
  assert.equal(timers.intervals.size, 0);
  assert.equal(timers.cleared.length, 1);
});

test("error followed by close requests exactly one external reconnect", () => {
  const { bridge, reconnectRequests, states } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  socket.emitError();
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(reconnectRequests(), 1);
  assert.equal(socket.closeCalls, 1);

  socket.emitClose();
  assert.equal(reconnectRequests(), 1);
  assert.deepEqual(states.at(-1), [NativeBridgeState.CONNECTED, NativeBridgeState.DISCONNECTED]);
});

test("retryNow clears the reconnect latch and starts immediately", () => {
  const { bridge, reconnectRequests } = makeHarness();
  bridge.connect();
  const first = FakeWebSocket.instances[0];
  first.emitClose();
  assert.equal(reconnectRequests(), 1);

  assert.equal(bridge.retryNow(), true);
  assert.equal(bridge.state, NativeBridgeState.CONNECTING);
  assert.equal(FakeWebSocket.instances.length, 2);

  FakeWebSocket.instances[1].emitError();
  assert.equal(reconnectRequests(), 2);
});

test("stop clears keepalive, closes the socket, and suppresses reconnect", () => {
  const { bridge, reconnectRequests, timers } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  bridge.stop();
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(socket.closeCalls, 1);
  assert.equal(timers.intervals.size, 0);
  assert.equal(reconnectRequests(), 0);

  socket.emitClose();
  socket.emitError();
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(reconnectRequests(), 0);
});

test("an explicit connect can resume after an intentional stop", () => {
  const { bridge } = makeHarness();
  bridge.connect();
  const first = FakeWebSocket.instances[0];
  first.open();
  bridge.stop();

  assert.equal(bridge.connect(), true);
  const second = FakeWebSocket.instances[1];
  second.open();
  assert.equal(bridge.state, NativeBridgeState.CONNECTED);
});

test("stale close, error, open, and message callbacks cannot affect a replacement", () => {
  const { bridge, reconnectRequests, messages, timers } = makeHarness();
  bridge.connect();
  const first = FakeWebSocket.instances[0];
  first.emitError();
  assert.equal(reconnectRequests(), 1);

  bridge.retryNow();
  const second = FakeWebSocket.instances[1];
  second.open();
  const replacementTimerIDs = [...timers.intervals.keys()];

  first.emitClose();
  first.emitError();
  first.open();
  first.emitMessage('{"type":"dismissRegionHighlight","data":{}}');

  assert.equal(bridge.state, NativeBridgeState.CONNECTED);
  assert.equal(reconnectRequests(), 1);
  assert.deepEqual([...timers.intervals.keys()], replacementTimerIDs);
  assert.deepEqual(messages, []);
  assert.equal(bridge.send({ type: "tabActivity", data: { reason: "test" } }), true);
  assert.equal(second.sent.length, 1);
});

test("native text messages are parsed and malformed or non-text frames are ignored", () => {
  const { bridge, messages } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  socket.emitMessage('{"type":"shortcutConfig","data":{"grab-element":{}}}');
  socket.emitMessage("not-json");
  socket.emitMessage(new Uint8Array([1, 2, 3]));

  assert.deepEqual(messages, [
    { type: "shortcutConfig", data: { "grab-element": {} } },
  ]);
});

test("constructor failure returns to disconnected and requests a reconnect", () => {
  const { bridge, reconnectRequests, states } = makeHarness();
  FakeWebSocket.constructorError = new Error("cannot construct");

  assert.equal(bridge.connect(), false);
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(reconnectRequests(), 1);
  assert.deepEqual(states, [
    [NativeBridgeState.DISCONNECTED, NativeBridgeState.CONNECTING],
    [NativeBridgeState.CONNECTING, NativeBridgeState.DISCONNECTED],
  ]);
});

test("serialization failure returns a negative acknowledgement without dropping the socket", () => {
  const { bridge, reconnectRequests } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  assert.equal(bridge.send({ data: 1n }), false);
  assert.equal(bridge.state, NativeBridgeState.CONNECTED);
  assert.equal(socket.closeCalls, 0);
  assert.equal(reconnectRequests(), 0);
});

test("socket send failure disconnects, closes, and requests one reconnect", () => {
  const { bridge, reconnectRequests, timers } = makeHarness();
  bridge.connect();
  const socket = FakeWebSocket.instances[0];
  socket.open();

  socket.send = () => {
    throw new Error("write failed");
  };
  assert.equal(bridge.send({ type: "tabActivity", data: {} }), false);
  assert.equal(bridge.state, NativeBridgeState.DISCONNECTED);
  assert.equal(socket.closeCalls, 1);
  assert.equal(timers.intervals.size, 0);
  assert.equal(reconnectRequests(), 1);

  socket.emitClose();
  assert.equal(reconnectRequests(), 1);
});
