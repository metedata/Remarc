export const PopupHintAction = Object.freeze({
  RETRY_WORKER: "retry-worker",
  RELOAD_TAB: "reload-tab",
});

export const POPUP_CONNECTION_POLL_INTERVAL_MS = 500;
export const POPUP_CONNECTION_POLL_MAX_ATTEMPTS = 20;

export function shouldContinueConnectionPolling({
  connected = false,
  attempts = 0,
  maxAttempts = POPUP_CONNECTION_POLL_MAX_ATTEMPTS,
} = {}) {
  return connected !== true && attempts >= 0 && attempts < maxAttempts;
}

export function isCurrentContentStatus(response) {
  return (
    response?.available === true &&
    typeof response.enabled === "boolean" &&
    !("connected" in response) &&
    !("lnaBlocked" in response)
  );
}

export function isContentStateSynchronized(response, enabled) {
  return isCurrentContentStatus(response) && response.enabled === enabled;
}

export function shouldApplyBridgeState({
  currentInstanceId = null,
  currentEpoch = -1,
  incomingInstanceId = null,
  incomingEpoch = null,
} = {}) {
  const hasIncomingClock =
    typeof incomingInstanceId === "string" &&
    incomingInstanceId.length > 0 &&
    Number.isSafeInteger(incomingEpoch) &&
    incomingEpoch >= 0;
  if (!hasIncomingClock) return currentInstanceId === null;
  if (incomingInstanceId !== currentInstanceId) return true;
  return incomingEpoch > currentEpoch;
}

export function derivePopupState({
  connected = false,
  enabled = true,
  contentAvailable = false,
  tabInjectable = false,
  tabNeedsReload = false,
} = {}) {
  const isConnected = connected === true;
  const isEnabled = enabled !== false;
  const hasContent = contentAvailable === true;
  const canInject = tabInjectable === true;
  const paused = !isEnabled;
  const needsTabReload =
    isConnected && isEnabled && canInject && !hasContent && tabNeedsReload === true;
  const unsupportedTab = isConnected && isEnabled && !canInject && !hasContent;

  let status = "disconnected";
  let statusText = "Disconnected";
  let statusTitle = "Launch Remarc macOS app, then retry the connection";

  if (paused) {
    status = "paused";
    statusText = "Paused";
    statusTitle = "";
  } else if (isConnected) {
    status = "connected";
    statusText = "Connected";
    if (needsTabReload) {
      statusTitle = "Remarc is connected. Reload this page to enable popup controls.";
    } else if (unsupportedTab) {
      statusTitle = "Remarc is connected, but this page cannot be controlled.";
    } else {
      statusTitle = "";
    }
  }

  let hintVisible = false;
  let hintText = "";
  let hintTitle = "";
  let hintAction = null;

  if (!paused && !isConnected) {
    hintVisible = true;
    hintText = "Launch Remarc or retry";
    hintTitle = "Retry Remarc connection";
    hintAction = PopupHintAction.RETRY_WORKER;
  } else if (needsTabReload) {
    hintVisible = true;
    hintText = "Reload page to enable controls";
    hintTitle = "Reload page";
    hintAction = PopupHintAction.RELOAD_TAB;
  } else if (unsupportedTab) {
    hintVisible = true;
    hintText = "Open a web page to enable controls";
  }

  return {
    status,
    statusText,
    statusTitle,
    controlsEnabled: isConnected && isEnabled && hasContent,
    settingsEnabled: isConnected && hasContent,
    powerVisible: isConnected || paused,
    powerTitle: isEnabled ? "Pause extension" : "Resume extension",
    showPauseIcon: isEnabled,
    hintVisible,
    hintText,
    hintTitle,
    hintAction,
    needsTabReload,
  };
}
