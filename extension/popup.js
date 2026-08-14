// popup.js — Extension popup UI logic

import {
  POPUP_CONNECTION_POLL_INTERVAL_MS,
  POPUP_CONNECTION_POLL_MAX_ATTEMPTS,
  PopupHintAction,
  derivePopupState,
  isContentStateSynchronized,
  isCurrentContentStatus,
  shouldApplyBridgeState,
  shouldContinueConnectionPolling,
} from "./popup-state.mjs";

const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const grabBtn = document.getElementById("grabBtn");
const regionBtn = document.getElementById("regionBtn");
const powerBtn = document.getElementById("powerBtn");
const pauseIcon = document.getElementById("pauseIcon");
const playIcon = document.getElementById("playIcon");
const statusPill = document.getElementById("statusPill");
const settingsBtn = document.getElementById("settingsBtn");
const reconnectHint = document.getElementById("reconnectHint");
const reconnectText = document.getElementById("reconnectText");
const reconnectBtn = document.getElementById("reconnectBtn");

const CONTENT_STATE_SYNC_INTERVAL_MS = 50;
const CONTENT_STATE_SYNC_MAX_ATTEMPTS = 20;

let isEnabled = false;
let enabledStateReady = false;
let isConnected = false;
let bridgeInstanceId = null;
let bridgeStateEpoch = -1;
let contentAvailable = false;
let activeTabInjectable = false;
let activeTabId = null;
let activeTabNeedsReload = false;
let activeTabProbeGeneration = 0;
let connectionPollAttempts = 0;
let connectionPollTimer = null;
let connectionRetryTimer = null;
let contentStateSyncTimer = null;
let popupUnloading = false;

function formatShortcut(config) {
  const symbolMap = { Meta: "\u2318", Control: "\u2303", Alt: "\u2325", Shift: "\u21E7" };
  const order = ["Control", "Alt", "Shift", "Meta"];
  const symbols = order
    .filter((modifier) => config.modifiers.includes(modifier))
    .map((modifier) => symbolMap[modifier])
    .join("");
  return symbols + config.key.toUpperCase();
}

function updateShortcutLabels() {
  const defaults = {
    "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
    "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
  };

  chrome.storage.local.get("shortcuts", (result) => {
    const shortcuts = result.shortcuts || defaults;
    document.getElementById("grabShortcut").textContent = formatShortcut(
      shortcuts["grab-element"] || defaults["grab-element"]
    );
    document.getElementById("regionShortcut").textContent = formatShortcut(
      shortcuts["region-select"] || defaults["region-select"]
    );
  });
}

function isInjectableTab(tab) {
  return /^https?:\/\//.test(tab?.url || "") || /^file:\/\//.test(tab?.url || "");
}

function currentViewState() {
  return derivePopupState({
    connected: isConnected,
    enabled: isEnabled,
    contentAvailable,
    tabInjectable: activeTabInjectable,
    tabNeedsReload: activeTabNeedsReload,
  });
}

function render() {
  const view = currentViewState();

  grabBtn.disabled = !view.controlsEnabled;
  regionBtn.disabled = !view.controlsEnabled;
  settingsBtn.disabled = !view.settingsEnabled;

  powerBtn.style.display = view.powerVisible ? "" : "none";
  pauseIcon.style.display = view.showPauseIcon ? "" : "none";
  playIcon.style.display = view.showPauseIcon ? "none" : "";
  powerBtn.title = view.powerTitle;
  powerBtn.classList.toggle("paused", !isEnabled);

  reconnectHint.style.display = view.hintVisible ? "" : "none";
  reconnectText.textContent = view.hintText;
  reconnectBtn.style.display = view.hintAction ? "" : "none";
  reconnectBtn.title = view.hintTitle;

  statusDot.className = view.status === "disconnected"
    ? "status-dot"
    : `status-dot ${view.status}`;
  statusText.textContent = view.statusText;
  statusPill.title = view.statusTitle;
}

function sendRuntimeMessage(message, callback = () => {}) {
  try {
    chrome.runtime.sendMessage(message, (response) => {
      const failed = !!chrome.runtime.lastError;
      callback(failed ? null : response);
    });
  } catch {
    callback(null);
  }
}

function stopConnectionPolling() {
  if (connectionPollTimer !== null) {
    clearTimeout(connectionPollTimer);
    connectionPollTimer = null;
  }
}

function stopConnectionTracking() {
  stopConnectionPolling();
  if (connectionRetryTimer !== null) {
    clearTimeout(connectionRetryTimer);
    connectionRetryTimer = null;
  }
  if (contentStateSyncTimer !== null) {
    clearTimeout(contentStateSyncTimer);
    contentStateSyncTimer = null;
  }
}

function setConnectionState(
  connected,
  { incomingInstanceId = null, incomingEpoch = null } = {}
) {
  if (!shouldApplyBridgeState({
    currentInstanceId: bridgeInstanceId,
    currentEpoch: bridgeStateEpoch,
    incomingInstanceId,
    incomingEpoch,
  })) {
    return false;
  }
  if (typeof incomingInstanceId === "string" && Number.isSafeInteger(incomingEpoch)) {
    bridgeInstanceId = incomingInstanceId;
    bridgeStateEpoch = incomingEpoch;
  }
  const nextConnected = connected === true;
  const becameConnected = nextConnected && !isConnected;
  isConnected = nextConnected;
  // Let an explicit retry's completion callback run so it can restore its
  // button state. Only the longer-running poll becomes redundant on success.
  if (isConnected) stopConnectionPolling();
  render();
  if (becameConnected) queryActiveTabStatus();
  return true;
}

function queryGlobalConnectionState(callback = () => {}) {
  sendRuntimeMessage({ type: "get-connection-state" }, (state) => {
    if (typeof state?.connected === "boolean") {
      setConnectionState(state.connected, {
        incomingInstanceId: state.bridgeInstanceId,
        incomingEpoch: state.bridgeStateEpoch,
      });
    }
    callback();
  });
}

function scheduleConnectionPoll({ reset = false } = {}) {
  if (reset) {
    stopConnectionPolling();
    connectionPollAttempts = 0;
  }
  if (
    popupUnloading ||
    connectionPollTimer !== null ||
    !shouldContinueConnectionPolling({
      connected: isConnected,
      attempts: connectionPollAttempts,
      maxAttempts: POPUP_CONNECTION_POLL_MAX_ATTEMPTS,
    })
  ) {
    return;
  }

  connectionPollTimer = setTimeout(() => {
    connectionPollTimer = null;
    if (popupUnloading || isConnected) return;
    connectionPollAttempts += 1;
    queryGlobalConnectionState(() => scheduleConnectionPoll());
  }, POPUP_CONNECTION_POLL_INTERVAL_MS);
}

function retryWorker(callback = () => {}) {
  stopConnectionTracking();
  connectionPollAttempts = 0;
  sendRuntimeMessage({ type: "retry-connect" }, () => {
    if (popupUnloading) return;
    connectionRetryTimer = setTimeout(() => {
      connectionRetryTimer = null;
      queryGlobalConnectionState(() => {
        if (!isConnected) scheduleConnectionPoll();
        callback();
      });
    }, 200);
  });
}

function probeActiveTabContent(
  tab,
  generation,
  { allowInjection = true, stateSyncAttempt = 0 } = {}
) {
  if (generation !== activeTabProbeGeneration || tab.id !== activeTabId) return;

  chrome.tabs.sendMessage(tab.id, { type: "get-status" }, (response) => {
    const failed = !!chrome.runtime.lastError;
    if (
      popupUnloading ||
      generation !== activeTabProbeGeneration ||
      tab.id !== activeTabId
    ) {
      return;
    }

    if (!failed && isCurrentContentStatus(response)) {
      if (!isContentStateSynchronized(response, isEnabled)) {
        contentAvailable = false;
        activeTabNeedsReload = false;
        render();
        if (stateSyncAttempt < CONTENT_STATE_SYNC_MAX_ATTEMPTS) {
          if (contentStateSyncTimer !== null) clearTimeout(contentStateSyncTimer);
          contentStateSyncTimer = setTimeout(() => {
            contentStateSyncTimer = null;
            probeActiveTabContent(tab, generation, {
              allowInjection: false,
              stateSyncAttempt: stateSyncAttempt + 1,
            });
          }, CONTENT_STATE_SYNC_INTERVAL_MS);
        }
        return;
      }
      contentAvailable = true;
      activeTabNeedsReload = false;
      render();
      return;
    }

    if (!failed || !allowInjection) {
      // A responder with the legacy status shape, or a failed re-probe after
      // injection, cannot be safely replaced without reloading the document.
      contentAvailable = false;
      activeTabNeedsReload = true;
      render();
      return;
    }

    if (!isConnected || !isEnabled || !activeTabInjectable) return;

    injectContentScripts(tab.id, (injected) => {
      if (
        popupUnloading ||
        generation !== activeTabProbeGeneration ||
        tab.id !== activeTabId
      ) {
        return;
      }
      if (!injected) {
        contentAvailable = false;
        activeTabNeedsReload = true;
        render();
        return;
      }
      probeActiveTabContent(tab, generation, { allowInjection: false });
    });
  });
}

function queryActiveTabStatus() {
  const generation = ++activeTabProbeGeneration;
  chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
    if (popupUnloading || generation !== activeTabProbeGeneration) return;
    activeTabId = tab?.id ?? null;
    activeTabInjectable = isInjectableTab(tab);
    contentAvailable = false;
    activeTabNeedsReload = false;
    render();

    if (activeTabId === null) return;
    probeActiveTabContent(tab, generation);
  });
}

function injectContentScripts(tabId, callback) {
  if (!chrome.scripting?.executeScript) {
    callback(false);
    return;
  }

  chrome.scripting.executeScript(
    {
      target: { tabId },
      files: ["main-world.js"],
      world: "MAIN",
    },
    () => {
      if (chrome.runtime.lastError) {
        callback(false);
        return;
      }

      chrome.scripting.executeScript(
        {
          target: { tabId },
          files: ["content.js"],
          world: "ISOLATED",
        },
        () => callback(!chrome.runtime.lastError)
      );
    }
  );
}

function showTabUnavailable(tab) {
  contentAvailable = false;
  activeTabInjectable = isInjectableTab(tab);
  activeTabNeedsReload = activeTabInjectable;
  render();
}

function sendToTab(type) {
  chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
    if (!tab?.id || !isInjectableTab(tab)) {
      showTabUnavailable(tab);
      return;
    }

    const sendCommand = () => {
      chrome.tabs.sendMessage(tab.id, { type }, (response) => {
        if (chrome.runtime.lastError || response?.ok === false) {
          showTabUnavailable(tab);
          return;
        }
        window.close();
      });
    };

    chrome.tabs.sendMessage(tab.id, { type: "get-status" }, () => {
      if (chrome.runtime.lastError) {
        injectContentScripts(tab.id, (injected) => {
          if (!injected) {
            showTabUnavailable(tab);
            return;
          }
          sendCommand();
        });
      } else {
        sendCommand();
      }
    });
  });
}

updateShortcutLabels();

chrome.storage.local.get({ extensionEnabled: true }, (result) => {
  isEnabled = result.extensionEnabled !== false;
  enabledStateReady = true;
  render();
  queryActiveTabStatus();
  retryWorker();
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes.extensionEnabled) {
    isEnabled = changes.extensionEnabled.newValue;
  }
  if (changes.shortcuts?.newValue) updateShortcutLabels();
  render();
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type !== "bridge-state") return false;
  const wasConnected = isConnected;
  setConnectionState(message.connected, {
    incomingInstanceId: message.bridgeInstanceId,
    incomingEpoch: message.bridgeStateEpoch,
  });
  if (!isConnected) scheduleConnectionPoll({ reset: wasConnected });
  return false;
});

window.addEventListener(
  "unload",
  () => {
    popupUnloading = true;
    stopConnectionTracking();
  },
  { once: true }
);

powerBtn.addEventListener("click", () => {
  if (!enabledStateReady) return;
  isEnabled = !isEnabled;
  render();
  chrome.storage.local.set({ extensionEnabled: isEnabled }, () => {
    if (isEnabled) {
      queryActiveTabStatus();
      retryWorker();
    }
  });
});

grabBtn.addEventListener("click", () => sendToTab("grab-element"));
regionBtn.addEventListener("click", () => sendToTab("region-select"));
settingsBtn.addEventListener("click", () => sendToTab("open-settings"));

reconnectBtn.addEventListener("click", () => {
  const action = currentViewState().hintAction;
  if (action === PopupHintAction.RETRY_WORKER) {
    reconnectBtn.disabled = true;
    retryWorker(() => {
      reconnectBtn.disabled = false;
      queryActiveTabStatus();
    });
    return;
  }

  if (action === PopupHintAction.RELOAD_TAB && activeTabId !== null) {
    chrome.tabs.reload(activeTabId, () => window.close());
  }
});
