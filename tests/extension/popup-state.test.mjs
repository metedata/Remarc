import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  POPUP_CONNECTION_POLL_MAX_ATTEMPTS,
  PopupHintAction,
  derivePopupState,
  isContentStateSynchronized,
  isCurrentContentStatus,
  shouldApplyBridgeState,
  shouldContinueConnectionPolling,
} from "../../extension/popup-state.mjs";

const popupSource = readFileSync(
  new URL("../../extension/popup.js", import.meta.url),
  "utf8"
);

test("global disconnect offers a worker retry and disables tab controls", () => {
  const state = derivePopupState({
    connected: false,
    enabled: true,
    contentAvailable: true,
    tabInjectable: true,
  });

  assert.equal(state.status, "disconnected");
  assert.equal(state.controlsEnabled, false);
  assert.equal(state.hintVisible, true);
  assert.equal(state.hintText, "Launch Remarc or retry");
  assert.equal(state.hintAction, PopupHintAction.RETRY_WORKER);
});

test("connected tab being probed does not prematurely offer a reload", () => {
  const state = derivePopupState({
    connected: true,
    enabled: true,
    contentAvailable: false,
    tabInjectable: true,
    tabNeedsReload: false,
  });

  assert.equal(state.controlsEnabled, false);
  assert.equal(state.needsTabReload, false);
  assert.equal(state.hintVisible, false);
});

test("connected tab offers a reload after injection or legacy detection fails", () => {
  const state = derivePopupState({
    connected: true,
    enabled: true,
    contentAvailable: false,
    tabInjectable: true,
    tabNeedsReload: true,
  });

  assert.equal(state.status, "connected");
  assert.equal(state.controlsEnabled, false);
  assert.equal(state.needsTabReload, true);
  assert.equal(state.hintText, "Reload page to enable controls");
  assert.equal(state.hintAction, PopupHintAction.RELOAD_TAB);
});

test("paused state keeps Resume reachable even while disconnected", () => {
  const state = derivePopupState({
    connected: false,
    enabled: false,
    contentAvailable: false,
    tabInjectable: true,
  });

  assert.equal(state.status, "paused");
  assert.equal(state.controlsEnabled, false);
  assert.equal(state.powerVisible, true);
  assert.equal(state.powerTitle, "Resume extension");
  assert.equal(state.showPauseIcon, false);
  assert.equal(state.hintVisible, false);
});

test("ready state enables capture and settings controls", () => {
  const state = derivePopupState({
    connected: true,
    enabled: true,
    contentAvailable: true,
    tabInjectable: true,
  });

  assert.equal(state.status, "connected");
  assert.equal(state.controlsEnabled, true);
  assert.equal(state.settingsEnabled, true);
  assert.equal(state.powerVisible, true);
  assert.equal(state.hintVisible, false);
});

test("unsupported extension pages do not offer a futile reload", () => {
  const state = derivePopupState({
    connected: true,
    enabled: true,
    contentAvailable: false,
    tabInjectable: false,
  });

  assert.equal(state.controlsEnabled, false);
  assert.equal(state.hintText, "Open a web page to enable controls");
  assert.equal(state.hintAction, null);
});

test("connection polling is bounded and stops immediately on connection", () => {
  assert.equal(
    shouldContinueConnectionPolling({ connected: false, attempts: 0 }),
    true
  );
  assert.equal(
    shouldContinueConnectionPolling({
      connected: false,
      attempts: POPUP_CONNECTION_POLL_MAX_ATTEMPTS - 1,
    }),
    true
  );
  assert.equal(
    shouldContinueConnectionPolling({
      connected: false,
      attempts: POPUP_CONNECTION_POLL_MAX_ATTEMPTS,
    }),
    false
  );
  assert.equal(
    shouldContinueConnectionPolling({ connected: true, attempts: 0 }),
    false
  );
});

test("current content status excludes the pre-migration response shape", () => {
  assert.equal(isCurrentContentStatus({ available: true, enabled: true }), true);
  assert.equal(
    isCurrentContentStatus({
      available: true,
      enabled: true,
      connected: true,
      lnaBlocked: false,
    }),
    false
  );
  assert.equal(isCurrentContentStatus({ available: true }), false);
});

test("content controls stay unavailable until persisted enabled state matches the popup", () => {
  assert.equal(
    isContentStateSynchronized({ available: true, enabled: false }, true),
    false
  );
  assert.equal(
    isContentStateSynchronized({ available: true, enabled: true }, true),
    true
  );
});

test("bridge clocks reject stale callbacks but accept a restarted worker session", () => {
  assert.equal(
    shouldApplyBridgeState({
      currentInstanceId: "worker-a",
      currentEpoch: 4,
      incomingInstanceId: "worker-a",
      incomingEpoch: 3,
    }),
    false
  );
  assert.equal(
    shouldApplyBridgeState({
      currentInstanceId: "worker-a",
      currentEpoch: 4,
      incomingInstanceId: "worker-a",
      incomingEpoch: 4,
    }),
    false
  );
  assert.equal(
    shouldApplyBridgeState({
      currentInstanceId: "worker-a",
      currentEpoch: 4,
      incomingInstanceId: "worker-b",
      incomingEpoch: 0,
    }),
    true
  );
  assert.equal(
    shouldApplyBridgeState({ currentInstanceId: "worker-a", currentEpoch: 4 }),
    false
  );
});

test("popup polls across the initial delay, stops on unload, and re-probes after injection", () => {
  assert.match(popupSource, /connectionPollAttempts \+= 1/);
  assert.match(popupSource, /queryGlobalConnectionState\(\(\) => scheduleConnectionPoll\(\)\)/);
  assert.match(popupSource, /window\.addEventListener\(\s*"unload"/);
  assert.match(popupSource, /injectContentScripts\(tab\.id, \(injected\) =>/);
  assert.match(
    popupSource,
    /probeActiveTabContent\(tab, generation, \{ allowInjection: false \}\)/
  );
  assert.match(popupSource, /let isEnabled = false;/);
  assert.match(
    popupSource,
    /if \(isConnected\) stopConnectionPolling\(\);/
  );
  assert.match(popupSource, /stateSyncAttempt: stateSyncAttempt \+ 1/);
});
