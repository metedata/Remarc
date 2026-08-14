import { NativeBridgeState } from "./native-bridge.mjs";

export const NATIVE_MESSAGE_RUNTIME_TYPE = "native-message";
export const RECONNECT_ALARM_NAME = "remarc-native-reconnect";
export const RECONNECT_ALARM_DELAY_MINUTES = 0.5;
export const REGION_QUERY_FALLBACK_MS = 250;

// A captured context is normally only a few kilobytes. This ceiling prevents a
// compromised page from making the extension serialize an unbounded payload.
export const MAX_NATIVE_MESSAGE_BYTES = 1024 * 1024;

export const ALLOWED_PAGE_MESSAGE_TYPES = Object.freeze([
  "selectionContext",
  "elementGrab",
  "regionContext",
  "regionRect",
  "regionHighlightDismissed",
  "openExtensionSettings",
  "tabActivity",
  "hfQuickNote",
]);

const ALLOWED_PAGE_MESSAGE_TYPE_SET = new Set(ALLOWED_PAGE_MESSAGE_TYPES);

const CAPTURE_MESSAGE_TYPE_SET = new Set([
  "selectionContext",
  "elementGrab",
  "regionContext",
  "regionRect",
  "hfQuickNote",
]);

export const DEFAULT_SHORTCUTS = Object.freeze({
  "grab-element": Object.freeze({ key: "G", modifiers: Object.freeze(["Alt", "Shift"]) }),
  "region-select": Object.freeze({ key: "R", modifiers: Object.freeze(["Alt", "Shift"]) }),
  "hf-quick-note": Object.freeze({ key: "N", modifiers: Object.freeze(["Alt", "Shift"]) }),
});

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function isOptionalString(value) {
  return value === undefined || value === null || typeof value === "string";
}

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function isOptionalInteger(value) {
  return value === undefined || value === null || Number.isSafeInteger(value);
}

function isOptionalBoolean(value) {
  return value === undefined || value === null || typeof value === "boolean";
}

function isOptionalStringRecord(value) {
  return (
    value === undefined ||
    value === null ||
    (isPlainObject(value) && Object.values(value).every((entry) => typeof entry === "string"))
  );
}

function isOptionalAccessibility(value) {
  if (value === undefined || value === null || typeof value === "string") return true;
  return (
    isPlainObject(value) &&
    isOptionalString(value.role) &&
    isOptionalString(value.ariaLabel) &&
    isOptionalString(value.ariaDescribedby) &&
    isOptionalString(value.ariaHidden) &&
    isOptionalInteger(value.tabIndex) &&
    isOptionalBoolean(value.focusable)
  );
}

function isOptionalNearbyText(value) {
  if (value === undefined || value === null || typeof value === "string") return true;
  return (
    isPlainObject(value) &&
    isOptionalString(value.element) &&
    isOptionalString(value.before) &&
    isOptionalString(value.after)
  );
}

function isOptionalNearbyElements(value) {
  if (value === undefined || value === null || typeof value === "string") return true;
  return (
    Array.isArray(value) &&
    value.length <= 100 &&
    value.every(
      (entry) =>
        isPlainObject(entry) &&
        isOptionalString(entry.tag) &&
        isOptionalString(entry.classes) &&
        isOptionalString(entry.id) &&
        isOptionalString(entry.textSnippet)
    )
  );
}

function isOptionalBoundingBox(value) {
  return (
    value === undefined ||
    value === null ||
    (isPlainObject(value) &&
      isOptionalInteger(value.x) &&
      isOptionalInteger(value.y) &&
      isOptionalInteger(value.width) &&
      isOptionalInteger(value.height))
  );
}

function isWebContext(value) {
  if (!isPlainObject(value)) return false;
  const stringFields = [
    "componentName",
    "filePath",
    "reactComponents",
    "elementName",
    "elementPath",
    "selectedText",
    "cssClasses",
    "selector",
    "pageUrl",
    "hyperframesContext",
  ];
  return (
    stringFields.every((field) => isOptionalString(value[field])) &&
    (isOptionalString(value.computedStyles) || isOptionalStringRecord(value.computedStyles)) &&
    isOptionalAccessibility(value.accessibility) &&
    isOptionalNearbyText(value.nearbyText) &&
    isOptionalNearbyElements(value.nearbyElements) &&
    isOptionalBoundingBox(value.boundingBox)
  );
}

const PAGE_DATA_VALIDATORS = Object.freeze({
  selectionContext: isWebContext,
  elementGrab: isWebContext,
  regionContext(value) {
    return (
      isPlainObject(value) &&
      Array.isArray(value.elements) &&
      value.elements.length <= 20 &&
      value.elements.every(isWebContext) &&
      isOptionalString(value.queryId) &&
      isOptionalString(value.purpose)
    );
  },
  regionRect(value) {
    return (
      isPlainObject(value) &&
      isFiniteNumber(value.x) &&
      isFiniteNumber(value.y) &&
      isFiniteNumber(value.width) &&
      value.width >= 0 &&
      isFiniteNumber(value.height) &&
      value.height >= 0
    );
  },
  regionHighlightDismissed: isPlainObject,
  openExtensionSettings: isPlainObject,
  tabActivity(value) {
    return (
      isPlainObject(value) &&
      isNonEmptyString(value.reason) &&
      isOptionalString(value.pageUrl)
    );
  },
  hfQuickNote(value) {
    return (
      isPlainObject(value) &&
      isNonEmptyString(value.hyperframesContext) &&
      isOptionalString(value.pageUrl)
    );
  },
});

export function serializedByteLength(value) {
  try {
    const serialized = JSON.stringify(value);
    if (typeof serialized !== "string") return Infinity;
    return new TextEncoder().encode(serialized).byteLength;
  } catch {
    return Infinity;
  }
}

export function validatePageEnvelope(
  candidate,
  { maxBytes = MAX_NATIVE_MESSAGE_BYTES } = {}
) {
  if (!isPlainObject(candidate) || !ALLOWED_PAGE_MESSAGE_TYPE_SET.has(candidate.type)) {
    return { ok: false, reason: "unsupported-type" };
  }

  const validator = PAGE_DATA_VALIDATORS[candidate.type];
  if (!validator(candidate.data)) return { ok: false, reason: "invalid-data" };

  // Rebuild the envelope so extra runtime-only keys never reach the native wire.
  const envelope = { type: candidate.type, data: candidate.data };
  if (serializedByteLength(envelope) > maxBytes) {
    return { ok: false, reason: "payload-too-large" };
  }
  return { ok: true, envelope };
}

export function isInjectablePageURL(url) {
  return typeof url === "string" && /^(https?|file):\/\//i.test(url);
}

export function isTrustedContentSender(sender, runtimeId) {
  if (
    !sender ||
    sender.id !== runtimeId ||
    sender.frameId !== 0 ||
    !isNonEmptyString(sender.documentId) ||
    !Number.isInteger(sender.tab?.id) ||
    sender.tab.id < 0 ||
    !Number.isInteger(sender.tab?.windowId) ||
    sender.tab.windowId < 0
  ) {
    return false;
  }

  const senderURL = sender.url ?? sender.tab.url;
  return isInjectablePageURL(senderURL);
}

function isInternalExtensionSender(sender, runtimeId) {
  return sender?.id === runtimeId;
}

function isRegionQuery(message) {
  const data = message?.data;
  return (
    isPlainObject(message) &&
    message.type === "regionQuery" &&
    isPlainObject(data) &&
    isNonEmptyString(data.queryId) &&
    isFiniteNumber(data.screenX) &&
    isFiniteNumber(data.screenY) &&
    isFiniteNumber(data.width) &&
    isFiniteNumber(data.height)
  );
}

function isShortcutConfig(message) {
  return (
    isPlainObject(message) &&
    message.type === "shortcutConfig" &&
    isPlainObject(message.data)
  );
}

function isDismissMessage(message) {
  return (
    isPlainObject(message) &&
    message.type === "dismissRegionHighlight" &&
    isPlainObject(message.data)
  );
}

function cloneInteraction(record) {
  return record ? { ...record } : null;
}

export function createBackgroundController({
  runtime,
  tabs,
  storage,
  alarms,
  bridge,
  now = () => Date.now(),
  setTimeoutFn = globalThis.setTimeout?.bind(globalThis),
  clearTimeoutFn = globalThis.clearTimeout?.bind(globalThis),
  logger = console,
  getEnabled = () => true,
  workerInstanceId = globalThis.crypto?.randomUUID?.() ??
    `${Date.now()}-${Math.random().toString(36).slice(2)}`,
  maxNativeMessageBytes = MAX_NATIVE_MESSAGE_BYTES,
  regionQueryFallbackMs = REGION_QUERY_FALLBACK_MS,
} = {}) {
  if (!runtime?.id || typeof runtime.reload !== "function") {
    throw new TypeError("Background controller requires chrome.runtime");
  }
  if (typeof tabs?.sendMessage !== "function" || typeof tabs?.query !== "function") {
    throw new TypeError("Background controller requires chrome.tabs");
  }
  if (
    typeof storage?.local?.get !== "function" ||
    typeof storage?.local?.set !== "function"
  ) {
    throw new TypeError("Background controller requires chrome.storage.local");
  }
  if (
    typeof alarms?.get !== "function" ||
    typeof alarms?.create !== "function" ||
    typeof alarms?.clear !== "function"
  ) {
    throw new TypeError("Background controller requires chrome.alarms");
  }
  if (
    typeof bridge?.send !== "function" ||
    typeof bridge?.connect !== "function" ||
    typeof bridge?.retryNow !== "function" ||
    typeof bridge?.stop !== "function"
  ) {
    throw new TypeError("Background controller requires a NativeBridge");
  }
  if (typeof setTimeoutFn !== "function" || typeof clearTimeoutFn !== "function") {
    throw new TypeError("Background controller requires timer functions");
  }
  if (!isNonEmptyString(workerInstanceId)) {
    throw new TypeError("Background controller requires a worker instance ID");
  }

  const documentsByTab = new Map();
  const pendingRegionQueries = new Map();
  let lastInteraction = null;
  let shuttingDown = false;
  let lifecycleFanout = Promise.resolve();
  let reconnectAlarmOperation = Promise.resolve();
  let nativeMessageOperation = Promise.resolve();
  let bridgeStateEpoch = 0;

  function logError(message, error) {
    try {
      logger?.error?.(`[Remarc] ${message}`, error ?? "");
    } catch {
      // Logging must never break extension message handling.
    }
  }

  function targetFromSender(sender) {
    return {
      tabId: sender.tab.id,
      windowId: sender.tab.windowId,
      documentId: sender.documentId,
      frameId: sender.frameId,
      lastActivityAt: now(),
    };
  }

  function cancelPendingRegionQuery(queryId) {
    const pending = pendingRegionQueries.get(queryId);
    if (!pending) return false;
    clearTimeoutFn(pending.timerId);
    pendingRegionQueries.delete(queryId);
    return true;
  }

  function invalidatePendingForTarget(record) {
    for (const [queryId, pending] of pendingRegionQueries) {
      if (
        pending.primary?.tabId === record.tabId &&
        (!pending.primary.documentId || pending.primary.documentId === record.documentId)
      ) {
        // The old primary no longer identifies the current document. Removing
        // the exclusion lets a replacement document in the same tab answer.
        pending.primary = null;
        void runRegionFallback(queryId);
      }
    }
  }

  function recordInteraction(sender) {
    const record = targetFromSender(sender);
    const previous = documentsByTab.get(record.tabId);
    if (previous && previous.documentId !== record.documentId) {
      invalidatePendingForTarget(previous);
    }
    documentsByTab.set(record.tabId, record);
    lastInteraction = record;
    return record;
  }

  async function sendToTarget(target, message) {
    const options = target.documentId
      ? { documentId: target.documentId, frameId: target.frameId ?? 0 }
      : { frameId: target.frameId ?? 0 };
    await tabs.sendMessage(target.tabId, message, options);
  }

  async function queryTabs(queryInfo) {
    try {
      const result = await tabs.query(queryInfo);
      return Array.isArray(result) ? result : [];
    } catch (error) {
      logError("Could not query tabs", error);
      return [];
    }
  }

  async function getLastFocusedTarget() {
    const candidates = await queryTabs({ active: true, lastFocusedWindow: true });
    const tab = candidates.find(
      (candidate) => Number.isInteger(candidate?.id) && isInjectablePageURL(candidate.url)
    );
    if (!tab) return null;
    return {
      tabId: tab.id,
      windowId: Number.isInteger(tab.windowId) ? tab.windowId : null,
      documentId: null,
      frameId: 0,
      lastActivityAt: now(),
    };
  }

  function targetsMatch(left, right) {
    if (!left || !right) return false;
    if (left?.tabId !== right?.tabId) return false;
    if (right?.documentId) return left?.documentId === right.documentId;
    return (left?.frameId ?? 0) === (right?.frameId ?? 0);
  }

  async function collectBroadcastTargets({ excludeTarget = null } = {}) {
    const targets = new Map();
    for (const record of documentsByTab.values()) {
      if (!targetsMatch(record, excludeTarget)) {
        targets.set(record.tabId, cloneInteraction(record));
      }
    }

    for (const tab of await queryTabs({})) {
      const knownRecord = documentsByTab.get(tab?.id);
      const queriedTarget = {
        tabId: tab?.id,
        documentId: null,
        frameId: 0,
      };
      const excludedDocumentIsStillCurrent = excludeTarget?.documentId
        ? targetsMatch(knownRecord, excludeTarget)
        : targetsMatch(queriedTarget, excludeTarget);
      if (
        !Number.isInteger(tab?.id) ||
        excludedDocumentIsStillCurrent ||
        !isInjectablePageURL(tab.url) ||
        targets.has(tab.id)
      ) {
        continue;
      }
      targets.set(tab.id, {
        tabId: tab.id,
        windowId: Number.isInteger(tab.windowId) ? tab.windowId : null,
        documentId: null,
        frameId: 0,
        lastActivityAt: 0,
      });
    }
    return [...targets.values()];
  }

  async function sendToCurrentDocumentFallback(target, message) {
    try {
      await sendToTarget(target, message);
      return true;
    } catch {
      if (!target.documentId) return false;
      try {
        await sendToTarget({ ...target, documentId: null, frameId: 0 }, message);
        return true;
      } catch {
        return false;
      }
    }
  }

  async function broadcastToInjected(message, options = {}) {
    const targets = await collectBroadcastTargets(options);
    await Promise.allSettled(
      targets.map((target) => sendToCurrentDocumentFallback(target, message))
    );
    return targets.length;
  }

  function sendToExtensionPages(message) {
    if (typeof runtime.sendMessage !== "function") return Promise.resolve();
    return new Promise((resolve) => {
      try {
        runtime.sendMessage(message, () => {
          // An open popup receives this immediately. No receiver is also a
          // normal state, so consume lastError and keep lifecycle ordering.
          void runtime.lastError;
          resolve();
        });
      } catch {
        resolve();
      }
    });
  }

  function enqueueLifecycleMessages(messages) {
    lifecycleFanout = lifecycleFanout
      .catch((error) => logError("Lifecycle broadcast failed", error))
      .then(async () => {
        for (const message of messages) {
          await Promise.all([
            sendToExtensionPages(message),
            broadcastToInjected(message),
          ]);
        }
      });
    return lifecycleFanout;
  }

  async function runRegionFallback(queryId) {
    const pending = pendingRegionQueries.get(queryId);
    if (!pending) return 0;
    clearTimeoutFn(pending.timerId);
    pendingRegionQueries.delete(queryId);
    return broadcastToInjected(pending.message, {
      excludeTarget: pending.primary ?? null,
    });
  }

  async function routeRegionQuery(message) {
    const queryId = message.data.queryId;
    cancelPendingRegionQuery(queryId);

    let primary = lastInteraction ? cloneInteraction(lastInteraction) : null;
    if (primary) {
      const current = documentsByTab.get(primary.tabId);
      if (!current || current.documentId !== primary.documentId) primary = null;
    }
    if (!primary) primary = await getLastFocusedTarget();

    const timerId = setTimeoutFn(() => {
      void runRegionFallback(queryId);
    }, regionQueryFallbackMs);
    pendingRegionQueries.set(queryId, { message, primary, timerId });

    if (!primary) return runRegionFallback(queryId);
    try {
      await sendToTarget(primary, message);
      return 1;
    } catch {
      const current = documentsByTab.get(primary.tabId);
      if (targetsMatch(current, primary)) documentsByTab.delete(primary.tabId);
      return runRegionFallback(queryId);
    }
  }

  async function retryConnection() {
    if (shuttingDown) {
      return { started: false, connected: false };
    }
    const started = bridge.retryNow();
    if (bridge.state !== NativeBridgeState.CONNECTED) await ensureReconnectAlarm();
    return {
      started,
      connected: bridge.state === NativeBridgeState.CONNECTED,
    };
  }

  function handleRuntimeMessage(message, sender, sendResponse = () => {}) {
    if (message?.type === NATIVE_MESSAGE_RUNTIME_TYPE) {
      if (!isTrustedContentSender(sender, runtime.id)) {
        sendResponse({ delivered: false, rejected: true });
        return false;
      }
      if (shuttingDown) {
        // Keep capture payloads in the content-script FIFO until the replacement
        // worker is live; no page traffic may reopen an intentionally stopped
        // bridge while an extension update is draining.
        sendResponse({ delivered: false });
        return false;
      }

      const validation = validatePageEnvelope(message.envelope, {
        maxBytes: maxNativeMessageBytes,
      });
      if (!validation.ok) {
        sendResponse({ delivered: false, rejected: true });
        return false;
      }

      if (CAPTURE_MESSAGE_TYPE_SET.has(validation.envelope.type)) {
        const enabled = getEnabled();
        if (enabled !== true) {
          sendResponse({ delivered: false, rejected: enabled === false });
          return false;
        }
      }

      recordInteraction(sender);
      if (
        validation.envelope.type === "tabActivity" &&
        getEnabled() !== true
      ) {
        // Activity still updates in-memory routing while paused, but its URL is
        // unnecessary to native and must not cross the privacy boundary.
        sendResponse({ delivered: true });
        return false;
      }
      const delivered = bridge.send(validation.envelope) === true;
      const queryId =
        validation.envelope.type === "regionContext"
          ? validation.envelope.data.queryId
          : null;
      // A content script keeps an undelivered reply in its own FIFO. Keep the
      // routing fallback alive too; only a reply that reached native resolves
      // the outstanding query.
      if (delivered && isNonEmptyString(queryId)) cancelPendingRegionQuery(queryId);
      if (!delivered && bridge.state === NativeBridgeState.DISCONNECTED) bridge.connect();
      sendResponse({ delivered });
      return false;
    }

    if (message?.type === "get-connection-state") {
      if (!isInternalExtensionSender(sender, runtime.id)) return false;
      const enabled = getEnabled();
      sendResponse({
        connected: enabled === true && bridge.state === NativeBridgeState.CONNECTED,
        state: bridge.state,
        enabled: enabled === true,
        bridgeInstanceId: workerInstanceId,
        bridgeStateEpoch,
      });
      return false;
    }

    if (message?.type === "retry-connect") {
      if (!isInternalExtensionSender(sender, runtime.id)) return false;
      void retryConnection().then(sendResponse, (error) => {
        logError("Could not retry native connection", error);
        sendResponse({ started: false, connected: false });
      });
      return true;
    }

    return false;
  }

  async function processNativeMessage(message) {
    if (isShortcutConfig(message)) {
      const stored = await storage.local.get({ shortcuts: DEFAULT_SHORTCUTS });
      const existing = isPlainObject(stored?.shortcuts) ? stored.shortcuts : {};
      const shortcuts = {
        ...DEFAULT_SHORTCUTS,
        ...existing,
        ...message.data,
      };
      await storage.local.set({ shortcuts });
      return true;
    }
    if (isRegionQuery(message)) {
      await routeRegionQuery(message);
      return true;
    }
    if (isDismissMessage(message)) {
      await broadcastToInjected({ type: "dismissRegionHighlight", data: message.data });
      return true;
    }
    logError(`Rejected unknown or malformed native message '${message?.type ?? "unknown"}'`);
    return false;
  }

  function handleNativeMessage(message) {
    const result = nativeMessageOperation.then(() => processNativeMessage(message));
    nativeMessageOperation = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  function enqueueReconnectAlarmOperation(operation) {
    const result = reconnectAlarmOperation.then(operation);
    void result.catch((error) => logError("Reconnect alarm operation failed", error));
    reconnectAlarmOperation = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  function ensureReconnectAlarm() {
    return enqueueReconnectAlarmOperation(async () => {
      if (shuttingDown || bridge.state === NativeBridgeState.CONNECTED) return false;
      const existing = await alarms.get(RECONNECT_ALARM_NAME);
      if (shuttingDown || bridge.state === NativeBridgeState.CONNECTED || existing) return false;
      await alarms.create(RECONNECT_ALARM_NAME, {
        delayInMinutes: RECONNECT_ALARM_DELAY_MINUTES,
      });
      if (shuttingDown || bridge.state === NativeBridgeState.CONNECTED) {
        await alarms.clear(RECONNECT_ALARM_NAME);
        return false;
      }
      return true;
    });
  }

  function clearReconnectAlarm() {
    return enqueueReconnectAlarmOperation(() => alarms.clear(RECONNECT_ALARM_NAME));
  }

  function handleReconnectNeeded() {
    if (!shuttingDown) void ensureReconnectAlarm();
  }

  function handleBridgeStateChange(nextState, previousState) {
    const connected =
      nextState === NativeBridgeState.CONNECTED && getEnabled() === true;
    bridgeStateEpoch += 1;
    const messages = [{
      type: "bridge-state",
      connected,
      bridgeInstanceId: workerInstanceId,
      bridgeStateEpoch,
    }];

    if (connected) {
      void enqueueLifecycleMessages(messages);
      void clearReconnectAlarm();
      return;
    }
    if (nextState === NativeBridgeState.DISCONNECTED) {
      if (!shuttingDown) void ensureReconnectAlarm();
    }
    void enqueueLifecycleMessages(messages);
  }

  function handleEnabledChanged(enabled) {
    bridgeStateEpoch += 1;
    return enqueueLifecycleMessages([
      {
        type: "bridge-state",
        connected: enabled === true && bridge.state === NativeBridgeState.CONNECTED,
        bridgeInstanceId: workerInstanceId,
        bridgeStateEpoch,
      },
    ]);
  }

  async function handleAlarm(alarm) {
    if (alarm?.name !== RECONNECT_ALARM_NAME || shuttingDown) return false;
    bridge.retryNow();
    if (bridge.state !== NativeBridgeState.CONNECTED) await ensureReconnectAlarm();
    return true;
  }

  function handleTabRemoved(tabId) {
    const record = documentsByTab.get(tabId);
    documentsByTab.delete(tabId);
    if (lastInteraction?.tabId === tabId) lastInteraction = null;
    if (record) invalidatePendingForTarget(record);
  }

  function handleNavigationCommitted(details) {
    if (details?.frameId !== 0 || !Number.isInteger(details.tabId)) return;
    const record = documentsByTab.get(details.tabId);
    documentsByTab.delete(details.tabId);
    if (lastInteraction?.tabId === details.tabId) lastInteraction = null;
    invalidatePendingForTarget(
      record ?? { tabId: details.tabId, documentId: null, frameId: 0 }
    );
  }

  function handleTabUpdated(tabId, changeInfo) {
    if (changeInfo?.status === "loading" || typeof changeInfo?.url === "string") {
      handleNavigationCommitted({ tabId, frameId: 0 });
    }
  }

  function cancelAllPendingQueries() {
    for (const pending of pendingRegionQueries.values()) clearTimeoutFn(pending.timerId);
    pendingRegionQueries.clear();
  }

  async function handleUpdateAvailable() {
    if (shuttingDown) return;
    shuttingDown = true;
    cancelAllPendingQueries();
    bridge.stop();
    try {
      await clearReconnectAlarm();
    } catch (error) {
      logError("Could not clear reconnect alarm before update", error);
    } finally {
      runtime.reload();
    }
  }

  async function dispose() {
    shuttingDown = true;
    cancelAllPendingQueries();
    bridge.stop();
    await clearReconnectAlarm();
  }

  return Object.freeze({
    handleRuntimeMessage,
    handleNativeMessage,
    handleBridgeStateChange,
    handleEnabledChanged,
    handleReconnectNeeded,
    handleAlarm,
    handleTabRemoved,
    handleNavigationCommitted,
    handleTabUpdated,
    handleUpdateAvailable,
    ensureReconnectAlarm,
    clearReconnectAlarm,
    broadcastToInjected,
    dispose,
    getLastInteraction: () => cloneInteraction(lastInteraction),
    getPendingRegionQueryCount: () => pendingRegionQueries.size,
  });
}
