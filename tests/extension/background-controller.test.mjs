import test from "node:test";
import assert from "node:assert/strict";

import {
  MAX_NATIVE_MESSAGE_BYTES,
  DEFAULT_SHORTCUTS,
  RECONNECT_ALARM_DELAY_MINUTES,
  RECONNECT_ALARM_NAME,
  createBackgroundController,
  isTrustedContentSender,
  serializedByteLength,
  validatePageEnvelope,
} from "../../extension/background-controller.mjs";

function createTimers() {
  let nextId = 1;
  const pending = new Map();
  return {
    set(callback, delay) {
      const id = nextId++;
      pending.set(id, { callback, delay });
      return id;
    },
    clear(id) {
      pending.delete(id);
    },
    runAll() {
      const callbacks = [...pending.values()].map((entry) => entry.callback);
      pending.clear();
      for (const callback of callbacks) callback();
    },
    pending,
  };
}

function createHarness({
  bridgeState = "connected",
  tabsList = [],
  enabled = true,
  storedShortcuts = null,
} = {}) {
  const timers = createTimers();
  const sentToTabs = [];
  const tabFailures = new Set();
  const storageWrites = [];
  const alarmStore = new Map();
  const alarmCreates = [];
  const alarmClears = [];
  const sentToRuntime = [];
  const errors = [];
  const storageValues = storedShortcuts ? { shortcuts: storedShortcuts } : {};

  const runtime = {
    id: "remarc-extension-id",
    reloadCount: 0,
    reload() {
      this.reloadCount += 1;
    },
    sendMessage(message, callback) {
      sentToRuntime.push(message);
      callback?.();
    },
  };
  const tabs = {
    list: tabsList,
    async query(info) {
      if (info.active && info.lastFocusedWindow) {
        return this.list.filter((tab) => tab.active && tab.lastFocusedWindow !== false);
      }
      return this.list;
    },
    async sendMessage(tabId, message, options) {
      sentToTabs.push({ tabId, message, options });
      const targetKey = `${tabId}:${options?.documentId ?? "current"}`;
      if (tabFailures.has(tabId) || tabFailures.has(targetKey)) {
        throw new Error("missing receiver");
      }
      return { ok: true };
    },
  };
  const storage = {
    local: {
      async get(defaults) {
        return {
          ...defaults,
          ...storageValues,
        };
      },
      async set(value) {
        storageWrites.push(value);
        Object.assign(storageValues, value);
      },
    },
  };
  const alarms = {
    async get(name) {
      return alarmStore.get(name) ?? null;
    },
    async create(name, info) {
      alarmCreates.push({ name, info });
      alarmStore.set(name, { name, ...info });
    },
    async clear(name) {
      alarmClears.push(name);
      return alarmStore.delete(name);
    },
  };
  const bridge = {
    state: bridgeState,
    delivered: bridgeState === "connected",
    sends: [],
    connectCount: 0,
    retryCount: 0,
    stopCount: 0,
    send(envelope) {
      this.sends.push(envelope);
      return this.delivered;
    },
    connect() {
      this.connectCount += 1;
      return true;
    },
    retryNow() {
      this.retryCount += 1;
      return true;
    },
    stop() {
      this.stopCount += 1;
      this.state = "disconnected";
    },
  };

  const controller = createBackgroundController({
    runtime,
    tabs,
    storage,
    alarms,
    bridge,
    now: () => 123_456,
    setTimeoutFn: timers.set,
    clearTimeoutFn: timers.clear,
    logger: { error: (...args) => errors.push(args) },
    getEnabled: () => enabled,
    workerInstanceId: "worker-test",
  });

  return {
    controller,
    runtime,
    tabs,
    storage,
    storageWrites,
    alarms,
    alarmStore,
    alarmCreates,
    alarmClears,
    bridge,
    timers,
    sentToTabs,
    sentToRuntime,
    tabFailures,
    errors,
  };
}

function sender({
  tabId = 7,
  windowId = 3,
  documentId = "doc-a",
  frameId = 0,
  id = "remarc-extension-id",
  url = "https://example.com/page",
} = {}) {
  return {
    id,
    frameId,
    documentId,
    url,
    tab: { id: tabId, windowId, url },
  };
}

function dispatchRuntime(controller, message, from = sender()) {
  let response;
  const returned = controller.handleRuntimeMessage(message, from, (value) => {
    response = value;
  });
  return { response, returned };
}

function dispatchRuntimeAsync(controller, message, from = sender()) {
  return new Promise((resolve) => {
    const returned = controller.handleRuntimeMessage(message, from, (response) => {
      resolve({ response, returned });
    });
  });
}

function nativeRuntime(type, data, extraEnvelope = {}) {
  return {
    type: "native-message",
    envelope: { type, data, ...extraEnvelope },
  };
}

function regionQuery(queryId) {
  return {
    type: "regionQuery",
    data: {
      queryId,
      purpose: "screenshot",
      screenX: 1,
      screenY: 2,
      width: 30,
      height: 40,
      maxElements: 20,
    },
  };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

test("page-envelope validation enforces types, shapes, UTF-8 size, and exact wire keys", () => {
  const valid = validatePageEnvelope({
    type: "elementGrab",
    data: { pageUrl: "https://example.com" },
    ignored: "runtime-only",
  });
  assert.equal(valid.ok, true);
  assert.deepEqual(valid.envelope, {
    type: "elementGrab",
    data: { pageUrl: "https://example.com" },
  });

  assert.equal(validatePageEnvelope({ type: "unknown", data: {} }).ok, false);
  assert.equal(
    validatePageEnvelope({ type: "regionRect", data: { x: 0, y: 0, width: -1, height: 2 } }).ok,
    false
  );
  assert.equal(
    validatePageEnvelope({ type: "regionContext", data: { elements: "wrong" } }).ok,
    false
  );
  assert.equal(
    validatePageEnvelope({ type: "elementGrab", data: { pageUrl: 42 } }).reason,
    "invalid-data"
  );
  assert.equal(
    validatePageEnvelope({
      type: "elementGrab",
      data: { boundingBox: { x: 0.5, y: 1, width: 2, height: 3 } },
    }).reason,
    "invalid-data"
  );
  assert.equal(
    validatePageEnvelope({
      type: "elementGrab",
      data: { accessibility: { role: "button", focusable: "yes" } },
    }).reason,
    "invalid-data"
  );
  assert.equal(
    validatePageEnvelope({
      type: "elementGrab",
      data: {
        computedStyles: { color: "rgb(0, 0, 0)" },
        accessibility: { role: "button", tabIndex: 0, focusable: true },
        nearbyText: { before: "before", after: "after" },
        nearbyElements: [{ tag: "a", classes: "link", textSnippet: "Next" }],
      },
    }).ok,
    true
  );

  const unicode = { type: "elementGrab", data: { pageUrl: "😀" } };
  assert.ok(serializedByteLength(unicode) > JSON.stringify(unicode).length);
  assert.equal(validatePageEnvelope(unicode, { maxBytes: 10 }).reason, "payload-too-large");
  assert.equal(MAX_NATIVE_MESSAGE_BYTES, 1024 * 1024);
});

test("trusted sender must be this extension, a real top-frame tab, and an exact document", () => {
  assert.equal(isTrustedContentSender(sender(), "remarc-extension-id"), true);
  assert.equal(isTrustedContentSender(sender({ id: "another-extension" }), "remarc-extension-id"), false);
  assert.equal(isTrustedContentSender(sender({ frameId: 2 }), "remarc-extension-id"), false);
  assert.equal(isTrustedContentSender(sender({ documentId: "" }), "remarc-extension-id"), false);
  assert.equal(isTrustedContentSender(sender({ tabId: -1 }), "remarc-extension-id"), false);
  assert.equal(isTrustedContentSender(sender({ url: "chrome://settings" }), "remarc-extension-id"), false);
  const missingURL = sender();
  delete missingURL.url;
  delete missingURL.tab.url;
  assert.equal(isTrustedContentSender(missingURL, "remarc-extension-id"), false);
});

test("runtime forwarding tracks document activity while disconnected and preserves exact envelope", () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  harness.bridge.delivered = false;
  const message = nativeRuntime(
    "elementGrab",
    { pageUrl: "https://example.com", selector: "#hero" },
    { extra: "must not cross the socket" }
  );
  const { response, returned } = dispatchRuntime(harness.controller, message);

  assert.equal(returned, false);
  assert.deepEqual(response, { delivered: false });
  assert.deepEqual(harness.bridge.sends, [
    { type: "elementGrab", data: { pageUrl: "https://example.com", selector: "#hero" } },
  ]);
  assert.equal(harness.bridge.connectCount, 1);
  assert.deepEqual(harness.controller.getLastInteraction(), {
    tabId: 7,
    windowId: 3,
    documentId: "doc-a",
    frameId: 0,
    lastActivityAt: 123_456,
  });
});

test("malformed, oversized, and untrusted messages are permanent FIFO rejections", () => {
  const harness = createHarness();
  const invalid = dispatchRuntime(
    harness.controller,
    nativeRuntime("regionRect", { x: 0, y: 0, width: "huge", height: 1 })
  );
  assert.deepEqual(invalid.response, { delivered: false, rejected: true });

  const oversizedHarness = createHarness();
  const oversizedController = createBackgroundController({
    runtime: oversizedHarness.runtime,
    tabs: oversizedHarness.tabs,
    storage: { local: { get: async (defaults) => defaults, set: async () => {} } },
    alarms: oversizedHarness.alarms,
    bridge: oversizedHarness.bridge,
    setTimeoutFn: oversizedHarness.timers.set,
    clearTimeoutFn: oversizedHarness.timers.clear,
    maxNativeMessageBytes: 40,
  });
  const oversized = dispatchRuntime(
    oversizedController,
    nativeRuntime("elementGrab", { pageUrl: "https://example.com/a/very/long/path" })
  );
  assert.deepEqual(oversized.response, { delivered: false, rejected: true });

  const untrusted = dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" }),
    sender({ frameId: 1 })
  );
  assert.deepEqual(untrusted.response, { delivered: false, rejected: true });
  assert.equal(harness.bridge.sends.length, 0);
});

test("tabActivity is observed and acknowledged without requiring socket delivery", () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  harness.bridge.delivered = false;
  const { response } = dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus", pageUrl: "https://example.com" }),
    sender({ tabId: 11, windowId: 8, documentId: "doc-focus" })
  );
  assert.deepEqual(response, { delivered: false });
  assert.equal(harness.controller.getLastInteraction().documentId, "doc-focus");
  assert.equal(harness.bridge.connectCount, 1);
});

test("connection state and retry controls are internal-only and alarm-backed", async () => {
  const harness = createHarness({ bridgeState: "disconnected", enabled: false });
  const state = dispatchRuntime(
    harness.controller,
    { type: "get-connection-state" },
    { id: "remarc-extension-id" }
  );
  assert.deepEqual(state.response, {
    connected: false,
    state: "disconnected",
    enabled: false,
    bridgeInstanceId: "worker-test",
    bridgeStateEpoch: 0,
  });

  const retryPromise = dispatchRuntimeAsync(
    harness.controller,
    { type: "retry-connect" },
    { id: "remarc-extension-id" }
  );
  const retry = await retryPromise;
  assert.deepEqual(retry.response, { started: true, connected: false });
  assert.equal(retry.returned, true);
  assert.equal(harness.bridge.retryCount, 1);
  assert.deepEqual(harness.alarmCreates, [
    {
      name: RECONNECT_ALARM_NAME,
      info: { delayInMinutes: RECONNECT_ALARM_DELAY_MINUTES },
    },
  ]);
});

test("native shortcutConfig merges native keys without deleting extension-only shortcuts", async () => {
  const harness = createHarness({
    storedShortcuts: {
      "hf-quick-note": { key: "H", modifiers: ["Alt"] },
    },
  });
  const shortcuts = {
    "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
  };
  assert.equal(
    await harness.controller.handleNativeMessage({ type: "shortcutConfig", data: shortcuts }),
    true
  );
  assert.deepEqual(harness.storageWrites, [
    {
      shortcuts: {
        ...DEFAULT_SHORTCUTS,
        "hf-quick-note": { key: "H", modifiers: ["Alt"] },
        ...shortcuts,
      },
    },
  ]);
  assert.equal(await harness.controller.handleNativeMessage({ type: "surprise", data: {} }), false);
  assert.equal(harness.errors.length, 1);
});

test("native frames preserve arrival order across asynchronous shortcut storage", async () => {
  const harness = createHarness();
  const originalGet = harness.storage.local.get;
  let releaseFirstGet;
  let getCount = 0;
  harness.storage.local.get = async (defaults) => {
    getCount += 1;
    if (getCount === 1) {
      await new Promise((resolve) => {
        releaseFirstGet = resolve;
      });
    }
    return originalGet(defaults);
  };

  const first = harness.controller.handleNativeMessage({
    type: "shortcutConfig",
    data: { "grab-element": { key: "A", modifiers: ["Alt"] } },
  });
  const second = harness.controller.handleNativeMessage({
    type: "shortcutConfig",
    data: { "grab-element": { key: "B", modifiers: ["Alt"] } },
  });
  await tick();
  assert.equal(getCount, 1);

  releaseFirstGet();
  await Promise.all([first, second]);
  assert.equal(getCount, 2);
  assert.equal(
    harness.storageWrites.at(-1).shortcuts["grab-element"].key,
    "B"
  );
});

test("regionQuery targets the exact last-interacted document", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example" },
      { id: 9, windowId: 4, url: "https://two.example" },
    ],
  });
  dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "mousedown" }),
    sender({ tabId: 7, windowId: 3, documentId: "exact-document" })
  );
  harness.sentToTabs.length = 0;

  await harness.controller.handleNativeMessage(regionQuery("query-a"));
  assert.deepEqual(harness.sentToTabs, [
    {
      tabId: 7,
      message: regionQuery("query-a"),
      options: { documentId: "exact-document", frameId: 0 },
    },
  ]);
  assert.equal(harness.controller.getPendingRegionQueryCount(), 1);
});

test("matching regionContext cancels only its correlated fallback", async () => {
  const harness = createHarness({ tabsList: [{ id: 7, url: "https://one.example" }] });
  dispatchRuntime(harness.controller, nativeRuntime("tabActivity", { reason: "focus" }));
  await harness.controller.handleNativeMessage(regionQuery("query-one"));
  await harness.controller.handleNativeMessage(regionQuery("query-two"));
  assert.equal(harness.controller.getPendingRegionQueryCount(), 2);

  const response = dispatchRuntime(
    harness.controller,
    nativeRuntime("regionContext", {
      queryId: "query-one",
      purpose: "screenshot",
      elements: [{ pageUrl: "https://one.example" }],
    })
  );
  assert.deepEqual(response.response, { delivered: true });
  assert.equal(harness.controller.getPendingRegionQueryCount(), 1);
  assert.equal(harness.timers.pending.size, 1);
});

test("undelivered correlated regionContext keeps its fallback armed", async () => {
  const harness = createHarness({ tabsList: [{ id: 7, url: "https://one.example" }] });
  dispatchRuntime(harness.controller, nativeRuntime("tabActivity", { reason: "focus" }));
  await harness.controller.handleNativeMessage(regionQuery("still-pending"));
  harness.bridge.delivered = false;
  harness.bridge.state = "disconnected";

  const response = dispatchRuntime(
    harness.controller,
    nativeRuntime("regionContext", {
      queryId: "still-pending",
      purpose: "screenshot",
      elements: [{ pageUrl: "https://one.example" }],
    })
  );
  assert.deepEqual(response.response, { delivered: false });
  assert.equal(harness.controller.getPendingRegionQueryCount(), 1);
  assert.equal(harness.timers.pending.size, 1);
});

test("regionQuery falls back to every other injectable tab after 250 ms", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example" },
      { id: 9, windowId: 4, url: "https://two.example" },
      { id: 10, windowId: 4, url: "chrome://settings" },
    ],
  });
  dispatchRuntime(harness.controller, nativeRuntime("tabActivity", { reason: "focus" }));
  harness.sentToTabs.length = 0;
  await harness.controller.handleNativeMessage(regionQuery("fallback-query"));
  assert.equal([...harness.timers.pending.values()][0].delay, 250);

  harness.timers.runAll();
  await tick();
  assert.deepEqual(harness.sentToTabs.map((entry) => entry.tabId), [7, 9]);
  assert.equal(harness.controller.getPendingRegionQueryCount(), 0);
});

test("a documentless cold-worker primary is excluded from its normal fallback", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example", active: true },
      { id: 9, windowId: 4, url: "https://two.example" },
    ],
  });
  await harness.controller.handleNativeMessage(regionQuery("cold-query"));
  harness.timers.runAll();
  await tick();

  assert.deepEqual(
    harness.sentToTabs.map((entry) => entry.tabId),
    [7, 9]
  );
});

test("navigation clears a documentless primary exclusion for the replacement page", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example/new", active: true },
      { id: 9, windowId: 4, url: "https://two.example" },
    ],
  });
  await harness.controller.handleNativeMessage(regionQuery("cold-navigation"));
  harness.sentToTabs.length = 0;

  harness.controller.handleNavigationCommitted({ tabId: 7, frameId: 0 });
  await tick();
  assert.deepEqual(
    harness.sentToTabs.map((entry) => entry.tabId).sort((a, b) => a - b),
    [7, 9]
  );
});

test("same-tab navigation makes the replacement document a fallback target", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example/new" },
      { id: 9, windowId: 4, url: "https://two.example" },
    ],
  });
  dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" }),
    sender({ tabId: 7, documentId: "old-document" })
  );
  await harness.controller.handleNativeMessage(regionQuery("navigated-query"));
  harness.sentToTabs.length = 0;

  harness.controller.handleNavigationCommitted({ tabId: 7, frameId: 0 });
  await tick();

  assert.ok(
    harness.sentToTabs.some(
      (entry) =>
        entry.tabId === 7 &&
        entry.message.data.queryId === "navigated-query" &&
        entry.options?.documentId === undefined
    )
  );
});

test("stale exact-document broadcast retries the current top-frame document once", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example" },
      { id: 9, windowId: 4, url: "https://two.example/current" },
    ],
  });
  dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" }),
    sender({ tabId: 9, documentId: "stale-document" })
  );
  dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" }),
    sender({ tabId: 7, documentId: "primary-document" })
  );
  harness.tabFailures.add("9:stale-document");
  await harness.controller.handleNativeMessage(regionQuery("stale-fallback"));
  harness.sentToTabs.length = 0;

  harness.timers.runAll();
  await tick();

  const tabNineAttempts = harness.sentToTabs.filter((entry) => entry.tabId === 9);
  assert.deepEqual(
    tabNineAttempts.map((entry) => entry.options),
    [
      { documentId: "stale-document", frameId: 0 },
      { frameId: 0 },
    ]
  );
});

test("missing primary, tab removal, and navigation invalidate stale routing", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 7, windowId: 3, url: "https://one.example" },
      { id: 9, windowId: 4, url: "https://two.example" },
    ],
  });
  dispatchRuntime(harness.controller, nativeRuntime("tabActivity", { reason: "focus" }));
  await harness.controller.handleNativeMessage(regionQuery("removed"));
  harness.controller.handleTabRemoved(7);
  await tick();
  assert.equal(harness.controller.getLastInteraction(), null);
  assert.ok(harness.sentToTabs.some((entry) => entry.tabId === 9));

  dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" }),
    sender({ tabId: 9, windowId: 4, documentId: "before-navigation" })
  );
  harness.controller.handleNavigationCommitted({ tabId: 9, frameId: 0, documentId: "after" });
  assert.equal(harness.controller.getLastInteraction(), null);
});

test("native dismissal broadcasts while disconnect cleanup uses ordered bridge state", async () => {
  const harness = createHarness({
    tabsList: [
      { id: 1, url: "https://one.example" },
      { id: 2, url: "https://two.example" },
    ],
  });
  await harness.controller.handleNativeMessage({ type: "dismissRegionHighlight", data: {} });
  assert.deepEqual(harness.sentToTabs.map((entry) => entry.message.type), [
    "dismissRegionHighlight",
    "dismissRegionHighlight",
  ]);

  harness.sentToTabs.length = 0;
  harness.controller.handleBridgeStateChange("disconnected", "connected");
  await tick();
  const types = harness.sentToTabs.map((entry) => entry.message.type).sort();
  assert.deepEqual(types, [
    "bridge-state",
    "bridge-state",
  ]);
});

test("lifecycle fanouts stay ordered across delayed tab discovery", async () => {
  const harness = createHarness({
    tabsList: [{ id: 1, url: "https://one.example" }],
  });
  let releaseFirstQuery;
  let queryCount = 0;
  harness.tabs.query = async () => {
    queryCount += 1;
    if (queryCount === 1) {
      return new Promise((resolve) => {
        releaseFirstQuery = () => resolve(harness.tabs.list);
      });
    }
    return harness.tabs.list;
  };

  harness.controller.handleBridgeStateChange("disconnected", "connected");
  harness.controller.handleBridgeStateChange("connected", "disconnected");
  await tick();
  assert.deepEqual(harness.sentToTabs, []);

  releaseFirstQuery();
  await tick();
  await tick();
  await tick();
  assert.deepEqual(
    harness.sentToTabs.map((entry) => [entry.message.type, entry.message.connected]),
    [
      ["bridge-state", false],
      ["bridge-state", true],
    ]
  );
  assert.deepEqual(
    harness.sentToRuntime.map((message) => [message.type, message.connected]),
    [
      ["bridge-state", false],
      ["bridge-state", true],
    ]
  );
});

test("socket-open broadcasts stay fail-closed until persisted enabled state is true", async () => {
  const harness = createHarness({
    enabled: false,
    tabsList: [{ id: 1, url: "https://one.example" }],
  });
  harness.controller.handleBridgeStateChange("connected", "connecting");
  await tick();
  await tick();
  assert.deepEqual(harness.sentToRuntime, [
    {
      type: "bridge-state",
      connected: false,
      bridgeInstanceId: "worker-test",
      bridgeStateEpoch: 1,
    },
  ]);
  assert.deepEqual(harness.sentToTabs[0].message, {
    type: "bridge-state",
    connected: false,
    bridgeInstanceId: "worker-test",
    bridgeStateEpoch: 1,
  });
});

test("paused capture payloads are permanently rejected before routing or native delivery", () => {
  const harness = createHarness({ enabled: false });
  const capture = dispatchRuntime(
    harness.controller,
    nativeRuntime("selectionContext", { selectedText: "private" })
  );
  assert.deepEqual(capture.response, { delivered: false, rejected: true });
  assert.equal(harness.bridge.sends.length, 0);
  assert.equal(harness.controller.getLastInteraction(), null);

  const activity = dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" })
  );
  assert.deepEqual(activity.response, { delivered: true });
  assert.equal(harness.bridge.sends.length, 0);
  assert.equal(harness.controller.getLastInteraction().documentId, "doc-a");
});

test("capture waits without a permanent rejection while enabled state is loading", () => {
  const harness = createHarness({ enabled: null });
  const capture = dispatchRuntime(
    harness.controller,
    nativeRuntime("elementGrab", { pageUrl: "https://one.example" })
  );
  assert.deepEqual(capture.response, { delivered: false, rejected: false });
  assert.equal(harness.bridge.sends.length, 0);
});

test("reconnect alarm is named, idempotent, recreated after firing, and cleared on open", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  assert.equal(await harness.controller.ensureReconnectAlarm(), true);
  assert.equal(await harness.controller.ensureReconnectAlarm(), false);
  assert.equal(harness.alarmCreates.length, 1);

  harness.alarmStore.delete(RECONNECT_ALARM_NAME); // one-shot alarm has fired
  assert.equal(await harness.controller.handleAlarm({ name: RECONNECT_ALARM_NAME }), true);
  assert.equal(harness.bridge.retryCount, 1);
  assert.equal(harness.alarmCreates.length, 2);

  harness.bridge.state = "connected";
  harness.controller.handleBridgeStateChange("connected", "connecting");
  await tick();
  assert.ok(harness.alarmClears.includes(RECONNECT_ALARM_NAME));
});

test("an alarm lookup that resolves after connection cannot create a stale alarm", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  let resolveGet;
  harness.alarms.get = () =>
    new Promise((resolve) => {
      resolveGet = resolve;
    });

  const ensuring = harness.controller.ensureReconnectAlarm();
  await tick();
  harness.bridge.state = "connected";
  resolveGet(null);
  assert.equal(await ensuring, false);
  assert.equal(harness.alarmCreates.length, 0);
});

test("alarm failures are logged and do not poison the next serialized operation", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  const originalGet = harness.alarms.get;
  harness.alarms.get = async () => {
    throw new Error("alarm lookup failed");
  };
  await assert.rejects(harness.controller.ensureReconnectAlarm(), /alarm lookup failed/);
  await tick();
  assert.equal(harness.errors.length, 1);

  harness.alarms.get = originalGet;
  assert.equal(await harness.controller.ensureReconnectAlarm(), true);
  assert.equal(harness.alarmCreates.length, 1);
});

test("update shutdown stops bridge, clears alarm, reloads, and suppresses reconnect", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  await harness.controller.ensureReconnectAlarm();
  await harness.controller.handleUpdateAvailable();
  assert.equal(harness.bridge.stopCount, 1);
  assert.equal(harness.alarmStore.has(RECONNECT_ALARM_NAME), false);
  assert.equal(harness.runtime.reloadCount, 1);

  const createsBefore = harness.alarmCreates.length;
  harness.controller.handleReconnectNeeded();
  await tick();
  assert.equal(harness.alarmCreates.length, createsBefore);
});

test("update reload still occurs when alarm cleanup rejects", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  harness.alarms.clear = async () => {
    throw new Error("alarm backend unavailable");
  };
  await harness.controller.handleUpdateAvailable();
  assert.equal(harness.bridge.stopCount, 1);
  assert.equal(harness.runtime.reloadCount, 1);
});

test("update waits for an in-flight alarm create before the final clear and reload", async () => {
  const harness = createHarness({ bridgeState: "disconnected" });
  let resolveCreate;
  harness.alarms.create = async (name, info) => {
    harness.alarmCreates.push({ name, info });
    await new Promise((resolve) => {
      resolveCreate = resolve;
    });
    harness.alarmStore.set(name, { name, ...info });
  };

  const ensuring = harness.controller.ensureReconnectAlarm();
  await tick();
  assert.equal(typeof resolveCreate, "function");

  const updating = harness.controller.handleUpdateAvailable();
  await tick();
  assert.equal(harness.runtime.reloadCount, 0);

  const duringUpdate = dispatchRuntime(
    harness.controller,
    nativeRuntime("tabActivity", { reason: "focus" })
  );
  assert.deepEqual(duringUpdate.response, { delivered: false });
  assert.equal(harness.bridge.connectCount, 0);
  assert.equal(harness.bridge.sends.length, 0);

  resolveCreate();
  assert.equal(await ensuring, false);
  await updating;
  assert.equal(harness.alarmStore.has(RECONNECT_ALARM_NAME), false);
  assert.equal(harness.runtime.reloadCount, 1);
});
