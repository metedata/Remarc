// background.js — MV3 module service worker
// Owns the single extension-origin connection to Remarc and renders global state.

import { createBackgroundController } from "./background-controller.mjs";
import { NativeBridge, NativeBridgeState } from "./native-bridge.mjs";

const REMARC_WS_URL = "ws://127.0.0.1:9274";

let currentConnected = false;
let currentEnabled = false;
let currentEnabledReady = false;
let controller = null;

const DOT_COLOR = Object.freeze({
  connected: "#22c55e",
  disconnected: "#ef4444",
  paused: "#8888a0",
});

const bitmapCache = new Map();
const renderCache = new Map();
let iconGeneration = 0;

function loadBitmap(size) {
  let promise = bitmapCache.get(size);
  if (!promise) {
    promise = fetch(chrome.runtime.getURL(`icons/icon${size}.png`))
      .then((response) => response.blob())
      .then(createImageBitmap);
    bitmapCache.set(size, promise);
  }
  return promise;
}

async function renderIcon(size, status) {
  const key = `${size}:${status}`;
  let image = renderCache.get(key);
  if (image) return image;

  const bitmap = await loadBitmap(size);
  const canvas = new OffscreenCanvas(size, size);
  const context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0, size, size);

  const radius = Math.max(2, Math.round(size * 0.12));
  const centerX = size - radius;
  const centerY = radius;

  context.beginPath();
  context.arc(centerX, centerY, radius + 1, 0, Math.PI * 2);
  context.fillStyle = "#1a1a2e";
  context.fill();
  context.beginPath();
  context.arc(centerX, centerY, radius, 0, Math.PI * 2);
  context.fillStyle = DOT_COLOR[status] ?? DOT_COLOR.disconnected;
  context.fill();

  image = context.getImageData(0, 0, size, size);
  renderCache.set(key, image);
  return image;
}

function iconStatus() {
  if (!currentEnabled) return "paused";
  return currentConnected ? "connected" : "disconnected";
}

async function setActionIcon(tabId, status, generation) {
  try {
    const [image16, image32] = await Promise.all([
      renderIcon(16, status),
      renderIcon(32, status),
    ]);
    if (generation !== iconGeneration) return;

    const details = { imageData: { 16: image16, 32: image32 } };
    if (Number.isInteger(tabId)) details.tabId = tabId;
    chrome.action.setIcon(details, () => void chrome.runtime.lastError);
  } catch {
    if (generation !== iconGeneration || Number.isInteger(tabId)) return;
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

async function updateAllIcons() {
  const generation = ++iconGeneration;
  const status = iconStatus();
  void setActionIcon(null, status, generation);

  // Older versions installed per-tab icon overrides. Replace each one with the
  // new global status so no stale green/orange dot survives this migration.
  try {
    const tabs = await chrome.tabs.query({});
    if (generation !== iconGeneration) return;
    for (const tab of tabs) {
      if (Number.isInteger(tab.id)) void setActionIcon(tab.id, status, generation);
    }
  } catch {
    // The default icon still covers tabs without a surviving override.
  }
}

const bridge = new NativeBridge({
  url: REMARC_WS_URL,
  onStateChange(nextState, previousState) {
    currentConnected = nextState === NativeBridgeState.CONNECTED;
    void updateAllIcons();
    controller?.handleBridgeStateChange(nextState, previousState);
  },
  onMessage(message) {
    const handling = controller?.handleNativeMessage(message);
    handling?.catch?.((error) => console.error("[Remarc] Native message failed", error));
  },
  onReconnectNeeded() {
    controller?.handleReconnectNeeded();
  },
});

controller = createBackgroundController({
  runtime: chrome.runtime,
  tabs: chrome.tabs,
  storage: chrome.storage,
  alarms: chrome.alarms,
  bridge,
  getEnabled: () => (currentEnabledReady ? currentEnabled : null),
});

function startBridge() {
  bridge.connect();
  void controller.ensureReconnectAlarm();
}

chrome.runtime.onMessage.addListener(controller.handleRuntimeMessage);
chrome.alarms.onAlarm.addListener((alarm) => void controller.handleAlarm(alarm));
chrome.tabs.onRemoved.addListener(controller.handleTabRemoved);
chrome.tabs.onUpdated.addListener(controller.handleTabUpdated);
chrome.runtime.onStartup.addListener(startBridge);
chrome.runtime.onInstalled.addListener(startBridge);
chrome.runtime.onUpdateAvailable.addListener(() => {
  void controller.handleUpdateAvailable();
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes.extensionEnabled) return;
  currentEnabled = changes.extensionEnabled.newValue !== false;
  currentEnabledReady = true;
  void updateAllIcons();
  void controller.handleEnabledChanged(currentEnabled);
});

chrome.storage.local.get({ extensionEnabled: true }, (result) => {
  currentEnabled = result.extensionEnabled !== false;
  currentEnabledReady = true;
  void updateAllIcons();
  void controller.handleEnabledChanged(currentEnabled);
});

startBridge();
