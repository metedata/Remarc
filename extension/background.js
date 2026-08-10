// background.js — MV3 service worker
// Forwards keyboard shortcut commands to the active tab's content script.
// Manages toolbar icon with connection status dot overlay.

const WS_CONNECTED_KEY = "wsConnected";

let currentConnected = false;
let currentEnabled = true;
let didRestoreConnectionState = false;

/// Per-tab last-known content-script state. Each entry: { connected, lnaBlocked }.
/// Populated by `ws-status` messages from content.js (one per tab that has the script
/// loaded) and by `syncConnectionState()` at worker startup. Cleaned up on tab close.
/// Drives both the global badge (any tab connected => green) and per-tab icon overrides
/// (a tab whose content script is blocked by LNA shows orange when active, regardless of
/// what other tabs are doing).
const tabStates = new Map();

// Restore connection state from storage - if the extension was connected before
// reload, the old content script's WebSocket is still alive, so keep showing green
// until syncConnectionState rebuilds the per-tab map.
function applyStoredConnectionState(result) {
  didRestoreConnectionState = true;
  if (result?.[WS_CONNECTED_KEY] && !currentConnected) {
    currentConnected = true;
    updateDefaultIcon();
  }
}

chrome.storage.local.get(WS_CONNECTED_KEY, applyStoredConnectionState);

// --- Icon rendering: base icon + status dot via OffscreenCanvas ---

const DOT_COLOR = {
  connected: "#22c55e",
  blocked: "#f59e0b",
  disconnected: "#ef4444",
  paused: "#8888a0",
};

const bitmapCache = new Map(); // size -> Promise<ImageBitmap>
const renderCache = new Map(); // `${size}:${status}` -> ImageData

function loadBitmap(size) {
  let p = bitmapCache.get(size);
  if (!p) {
    p = fetch(chrome.runtime.getURL(`icons/icon${size}.png`))
      .then((r) => r.blob())
      .then(createImageBitmap);
    bitmapCache.set(size, p);
  }
  return p;
}

async function renderIcon(size, status) {
  const key = `${size}:${status}`;
  let img = renderCache.get(key);
  if (img) return img;
  const bitmap = await loadBitmap(size);
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0, size, size);

  const dotColor = DOT_COLOR[status] || DOT_COLOR.disconnected;
  const dotRadius = Math.max(2, Math.round(size * 0.12));
  const cx = size - dotRadius;
  const cy = dotRadius;

  ctx.beginPath();
  ctx.arc(cx, cy, dotRadius + 1, 0, Math.PI * 2);
  ctx.fillStyle = "#1a1a2e";
  ctx.fill();
  ctx.beginPath();
  ctx.arc(cx, cy, dotRadius, 0, Math.PI * 2);
  ctx.fillStyle = dotColor;
  ctx.fill();

  img = ctx.getImageData(0, 0, size, size);
  renderCache.set(key, img);
  return img;
}

// Maps a tab's state (or null for the default icon) to a DOT_COLOR key.
function statusForTab(state) {
  if (!currentEnabled) return "paused";
  if (state?.connected) return "connected";
  if (state?.lnaBlocked) return "blocked";
  return currentConnected ? "connected" : "disconnected";
}

// `tabId === null` => set the global default icon (used for tabs we have no
// state for - chrome://, file://, fresh tabs). Per-tab `setIcon` calls
// override this default for tabs with explicit state, and Chrome swaps the
// icon automatically when one of those tabs becomes active.
const lastRenderedStatus = new Map(); // tabId | null -> status

async function setActionIcon(tabId, status) {
  if (lastRenderedStatus.get(tabId) === status) return;
  lastRenderedStatus.set(tabId, status);
  try {
    const [img16, img32] = await Promise.all([
      renderIcon(16, status),
      renderIcon(32, status),
    ]);
    const details = { imageData: { 16: img16, 32: img32 } };
    if (tabId !== null) details.tabId = tabId;
    chrome.action.setIcon(details, () => {
      // Tab may have closed mid-render; swallow the resulting lastError.
      void chrome.runtime.lastError;
    });
  } catch {
    if (tabId === null) {
      chrome.action.setIcon({
        path: {
          16: "icons/icon16.png",
          32: "icons/icon32.png",
          48: "icons/icon48.png",
          128: "icons/icon128.png",
        },
      });
    }
  }
}

const updateDefaultIcon = () => setActionIcon(null, statusForTab(null));
const updateTabIcon = (tabId) =>
  setActionIcon(tabId, statusForTab(tabStates.get(tabId)));

function recomputeConnectionState() {
  const anyConnected = [...tabStates.values()].some((s) => s?.connected);
  if (anyConnected === currentConnected) return;
  currentConnected = anyConnected;
  updateDefaultIcon();
  // Tabs without an explicit connected/lnaBlocked signal fall through to the
  // global status, so they need to re-render when it flips. updateTabIcon's
  // cache check makes this free for "anchored" tabs that don't depend on it.
  for (const tabId of tabStates.keys()) updateTabIcon(tabId);
  chrome.storage.local.set({ [WS_CONNECTED_KEY]: anyConnected });
}

function setTabState(tabId, state) {
  if (typeof tabId !== "number") return;
  const next = {
    connected: !!state?.connected,
    lnaBlocked: !!state?.lnaBlocked,
  };
  const prev = tabStates.get(tabId);
  if (prev && prev.connected === next.connected && prev.lnaBlocked === next.lnaBlocked) return;
  tabStates.set(tabId, next);
  updateTabIcon(tabId);
  if (prev?.connected !== next.connected) recomputeConnectionState();
}

// --- State changes ---

chrome.storage.onChanged.addListener((changes) => {
  if (changes.extensionEnabled) {
    currentEnabled = changes.extensionEnabled.newValue;
    updateDefaultIcon();
    for (const tabId of tabStates.keys()) updateTabIcon(tabId);
  }
});

chrome.storage.local.get({ extensionEnabled: true }, (result) => {
  currentEnabled = result.extensionEnabled;
  updateDefaultIcon();
});

// Content script reports connection changes; popup asks for current state.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === "ws-status") {
    setTabState(sender?.tab?.id, msg);
    return false;
  }

  if (msg.type === "get-connection-state") {
    const respond = () =>
      sendResponse({
        connected: currentConnected,
        enabled: currentEnabled,
      });

    if (didRestoreConnectionState) {
      respond();
      return false;
    }

    chrome.storage.local.get(WS_CONNECTED_KEY, (result) => {
      applyStoredConnectionState(result);
      respond();
    });
    return true;
  }

  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  const had = tabStates.delete(tabId);
  lastRenderedStatus.delete(tabId);
  if (had) recomputeConnectionState();
});

// Rebuild per-tab state on service worker startup by querying every tab,
// replacing the ws-status reports we missed while the worker was asleep.
async function syncConnectionState() {
  const tabs = await chrome.tabs.query({});
  await Promise.all(
    tabs.map(
      (tab) =>
        new Promise((resolve) => {
          if (typeof tab.id !== "number") return resolve();
          chrome.tabs.sendMessage(tab.id, { type: "get-status" }, (response) => {
            if (chrome.runtime.lastError || !response) return resolve();
            tabStates.set(tab.id, {
              connected: !!response.connected,
              lnaBlocked: !!response.lnaBlocked,
            });
            updateTabIcon(tab.id);
            resolve();
          });
        })
    )
  );
  recomputeConnectionState();
}
syncConnectionState();
