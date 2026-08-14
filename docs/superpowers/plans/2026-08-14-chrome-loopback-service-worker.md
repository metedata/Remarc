# Chrome Loopback Prompt Fix Implementation Plan

> **Baseline:** `a6d5e9b9745d7b5bea4b5efa4e04ff5af24d42f9` (`origin/main` on 2026-08-14)
>
> **Worktree:** `.worktrees/chrome-loopback-service-worker`
>
> **Branch:** `codex/chrome-loopback-service-worker`

**Goal:** Stop Chrome 147+ from asking every visited website for “Access other apps and services on this device” while preserving Remarc’s automatic web-context capture, shortcuts, region targeting, connection status, and local-only transport.

**Root cause:** `extension/content.js` is injected at `document_start` on `<all_urls>` and immediately constructs `ws://127.0.0.1:9274`. Chrome attributes content-script network traffic to the page origin, so every new site can request its own `loopback-network` permission. Chrome does not apply this per-site LNA gate to an extension-origin request when the extension has the necessary host permission.

**Architecture:** Move the only native WebSocket into the Manifest V3 background service worker. Content scripts send validated envelopes to the worker with `chrome.runtime.sendMessage`; the worker forwards only messages accepted while the socket is open. Each content script retains its bounded, memory-only FIFO until the worker acknowledges delivery, so worker suspension cannot silently discard captured page context and no page data is persisted. Native messages are routed back to the last-interacted document, with a timed all-tab fallback for region queries and broadcasts for connection/highlight state. Shortcut configuration is stored once in `chrome.storage.local`, which already fans changes out to every content script.

**Primary references:**

- Remarc issue #6: <https://github.com/metedata/Remarc/issues/6>
- Chrome 147 WebSocket LNA launch: <https://developer.chrome.com/release-notes/147#local-network-access-restrictions-for-websockets>
- Content-script versus extension-origin requests: <https://developer.chrome.com/docs/extensions/develop/concepts/network-requests>
- WebSockets in extension service workers: <https://developer.chrome.com/docs/extensions/how-to/web-platform/websockets>
- LNA adoption guidance, including the extension host-permission exemption: <https://docs.google.com/document/d/1QQkqehw8umtAgz5z0um7THx-aoU251p705FbIQjDuGs/edit?usp=sharing>

## Invariants

1. No content script or main-world script may open a loopback connection.
2. One extension profile owns at most one live WebSocket to `127.0.0.1:9274`.
3. All existing content-to-native message types retain their JSON wire shape.
4. `regionQuery` first targets the most recently active/interacted tab, then falls back to other injectable tabs after 250 ms if no matching `regionContext` arrives.
5. `dismissRegionHighlight` reaches every injected tab so no stale overlay survives.
6. Native shortcut updates reach existing and future tabs.
7. Worker restart, browser restart, app-not-running, socket close, tab close, and extension update all have an explicit recovery path. Tabs carrying the pre-migration 0.3.0 content script require one reload after update.
8. “Pause extension” cancels active capture interactions, blocks in-flight captures from forwarding, and never strands the user unable to resume.
9. The browser never needs a per-site `loopback-network` grant for Remarc.
10. Page context remains local to the extension and native app; no new remote endpoint or persisted browsing-content queue is introduced.

## Scope

### Files to add

- `extension/native-bridge.mjs` — testable WebSocket lifecycle, reconnect, keepalive, and stale-generation protection.
- `extension/background-controller.mjs` — testable Chrome messaging, validation, document routing, alarm, and update controller.
- `extension/popup-state.mjs` — pure popup state derivation for regression tests.
- `tests/extension/native-bridge.test.mjs` — socket lifecycle regression tests outside the packaged extension tree.
- `tests/extension/background-controller.test.mjs` — message validation, lifecycle, and tab-routing regression tests.
- `tests/extension/content-bridge.test.mjs` — content-script relay, FIFO, Pause, and bridge-clock source contracts.
- `tests/extension/popup-state.test.mjs` — popup connected/content-availability/pause behavior.
- `tests/extension/source-contracts.test.mjs` — manifest/content-script/packaging invariants that prevent LNA regression.

### Files to modify

- `extension/manifest.json` — module service worker, Chrome 120 minimum, and `alarms` permission. The release workflow retains ownership of the patch-version bump.
- `extension/background.js` — bootstrap the bridge/controller and retain icon rendering.
- `extension/content.js` — replace direct WebSocket code with extension messaging and native-command handlers.
- `extension/popup.js` — query/retry the global bridge instead of a per-tab socket and remove per-site LNA remediation UI.
- `extension/popup.html` — load the popup script as a module and remove obsolete permission-setting iconography.
- `extension/popup.css` — remove obsolete LNA-specific reconnect styling.
- `.github/workflows/ci.yml` — run dependency-free extension tests, syntax checks, and manifest validation.
- `docs-site/src/content/docs/chrome-extension.md` — describe the single extension-owned local connection and correct reconnect behavior.
- `docs-site/src/content/docs/getting-started/permissions.md` — distinguish Chrome’s removed per-site prompt from macOS permissions.

### Out of scope

- Publishing a new extension ZIP or changing the production download URL before an artifact exists.
- Changing the native Swift WebSocket message schema.
- Removing the native multi-client implementation; retaining it is backward-compatible with extension 0.3.0 and useful for tests/older clients.
- Adding authentication to the loopback protocol.
- Changing captured metadata or page-injection permissions.
- Publishing replacement-extension behavior on `website/public/chrome-extension/index.html` before the replacement ZIP exists; update it as part of the release.

## Task 1: Establish a testable extension module boundary

- [x] Add `native-bridge.mjs` with injected `WebSocket`, timer, and state callbacks so tests do not depend on Chrome globals.
- [x] Represent connection state as `disconnected`, `connecting`, or `connected`; make `connect()` idempotent.
- [x] Accept outbound envelopes only while `OPEN` and return a delivery acknowledgement; page payload queues stay in content-script memory.
- [x] On open, clear reconnect state, notify status, and start a 20-second application keepalive.
- [x] On close/error, stop keepalive, notify status, and request one alarm-backed reconnect without accumulating timers.
- [x] Give every socket attempt a generation identity so late callbacks from a stale socket cannot close or demote its replacement.
- [x] Make `retryNow()` clear reconnect state and start immediately.
- [x] Ensure `stop()` clears timers, closes the socket, and cannot reconnect from the resulting close callback.

**Tests:** idempotent connect; open-only delivery; one reconnect request; retry-now; stop suppression; keepalive interval; open/close state transitions; stale-socket close/error after replacement.

## Task 2: Move protocol ownership into the background worker

- [x] Add `background-controller.mjs` with injected Chrome APIs and bridge.
- [x] Accept content-script messages only from this extension, a real top-frame `sender.tab.id`, and the existing allowlisted native message types: `selectionContext`, `elementGrab`, `regionContext`, `regionRect`, `regionHighlightDismissed`, `openExtensionSettings`, `tabActivity`, and `hfQuickNote`.
- [x] Validate each message’s data shape and reject payloads above a documented serialized-byte ceiling before they reach the native app.
- [x] Preserve the native JSON envelope exactly as `{ "type": ..., "data": ... }`.
- [x] Record `{ tabId, windowId, documentId, frameId, lastActivityAt }` whenever an accepted tab message is observed, including while the native app is disconnected.
- [x] Handle native `shortcutConfig` by merging native-configurable keys into the complete shortcut set and writing once to `chrome.storage.local`.
- [x] Route native `regionQuery` to the exact last-interacted document; if delivery fails, the document navigated, state was lost, or no matching `regionContext` arrives within 250 ms, send it to other injectable tabs. Prefer the last-focused window only when no interaction record exists.
- [x] Cancel only the fallback belonging to the matching `queryId`; ignore stale/duplicate replies for routing purposes and let the native server retain final deduplication.
- [x] Broadcast native `dismissRegionHighlight`, and use ordered disconnect state to dismiss local overlays whenever the socket closes.
- [x] Treat unknown native messages as protocol errors in the extension console without forwarding them into pages.
- [x] On tab removal or top-level navigation, clear stale interaction/routing state for that document.
- [x] Expose versioned `get-connection-state` and `retry-connect` runtime messages for the popup.

**Tests:** sender/origin/frame validation; per-type shape and size limits; exact wire envelope; last-interacted document routing across windows; navigation/missing primary fallback; query-specific cancellation; overlapping query IDs; socket-close highlight cleanup; shortcut persistence; tab removal; unknown native message rejection.

## Task 3: Convert the background script to an extension-origin socket

- [x] Mark the service worker as a module, require `alarms`, and set `minimum_chrome_version` to `120` so a 30-second alarm is valid.
- [x] Use one named, one-shot 30-second reconnect alarm; check/recreate it at every worker startup and clear it on successful open.
- [x] Instantiate one `NativeBridge` at service-worker startup.
- [x] Keep connection state authoritative in memory; do not restore the old persisted `wsConnected=true` value after worker restart because the old worker’s socket cannot survive.
- [x] Preserve the toolbar’s connected/disconnected/paused icon states, but remove per-tab LNA-blocked state and orange-dot logic.
- [x] Start/retry the bridge on worker startup, extension startup/install, content-script activity, and explicit popup retry.
- [x] Send an application-level `tabActivity` keepalive before the 30-second worker idle deadline while connected.
- [x] Handle `runtime.onUpdateAvailable` at top level: intentionally stop the bridge, serialize alarm cleanup, reject page traffic during drain, then call `runtime.reload()` so the keepalive cannot starve updates.
- [x] Verify that all loopback construction now occurs only in the background module.

**Tests:** only one bridge instance; stale persisted status is ignored; startup/retry events are idempotent; alarm recreation/clearing; app-late-start alarm recovery; update shutdown cannot reconnect; icon state follows global bridge state.

## Task 4: Replace content-script networking with extension messaging

- [x] Delete `WebSocket`, LNA fingerprinting, per-tab reconnect timers, and `ws-status` reporting from `content.js`.
- [x] Retain a maximum-50 FIFO per tab in memory. Replace `send(type, data)` with `chrome.runtime.sendMessage`; remove an item only after the worker acknowledges open-socket delivery, then flush in order on the worker’s connected broadcast.
- [x] Do not queue disconnected `tabActivity`; the worker records its sender for routing and suppresses page URLs while paused or loading.
- [x] Keep the current activity signals (`init`, focus, visibility, and throttled mousedown) so the worker can identify the primary tab and wake/reconnect safely.
- [x] Add runtime handlers for `regionQuery`, `dismissRegionHighlight`, and versioned global bridge-state changes from the background worker.
- [x] Keep `shortcutConfig` synchronized through `chrome.storage.local`; do not create a second direct broadcast path.
- [x] Change `get-status` to report only content-script availability and enabled state; connection state belongs to the worker.
- [x] When paused, fail closed at startup, exit grab/region modes, remove overlays/listeners, and recheck enabled state after asynchronous context work before forwarding any capture.
- [x] Ensure failed extension messaging never breaks page selection, keyboard, or pointer handlers.

**Tests/source contracts:** `content.js` contains no `WebSocket` or loopback URL; native outbound types still call the replacement `send`; native inbound handlers remain reachable; queue cap/order and disconnect acknowledgement; pause during active and awaited captures.

## Task 5: Align popup and documentation behavior

- [x] Have the popup nudge `retry-connect` on the worker, then query global connection state.
- [x] Keep active-tab probing only to determine whether controls can run on that page.
- [x] Remove the “Apps on Device” / per-site permission branch; disconnected guidance says to launch Remarc or retry, while an uninjected tab still says to reload.
- [x] Make the retry button reconnect the worker instead of reloading an otherwise valid active tab.
- [x] Preserve the pause/resume UI and active-tab action injection behavior, including fail-closed startup and enabled-state propagation retries.
- [x] Extract popup state derivation into `popup-state.mjs` and test global-disconnected, connected-but-uninjected, paused, ready, and stale-state cases.
- [x] Update extension docs to say one extension-owned localhost connection serves all tabs and no per-site Chrome permission is expected on Chrome 147+.
- [x] Document Chrome Site Access restriction as an optional privacy/scope control, not as the fix for normal operation.
- [x] Leave the manifest at `0.3.0`; the tracked release workflow owns the dedicated patch-version commit immediately before packaging.

## Task 6: Verification

### Automated

- [x] `node --test tests/extension/*.test.mjs` — 62 tests pass.
- [x] Parse `extension/manifest.json` as JSON.
- [x] `node --check` every extension `.js` and `.mjs` module/script.
- [x] Run those extension checks in `.github/workflows/ci.yml` with pinned Node 22 setup.
- [x] Source-contract tests prove `ws://127.0.0.1:9274` exists only in the background bridge configuration and tests, never `content.js` or `main-world.js`.
- [x] `swift test` in `app/RemarcPackage` — 263 XCTest and 98 Swift Testing cases pass.
- [x] Debug build using the worktree’s absolute DerivedData path.
- [x] Relaunch the worktree build immediately after the successful build, as required by `AGENTS.md`; verified PID 33021 owns `127.0.0.1:9274`.

### Chrome 147+ runtime smoke test

- [x] Launch an isolated Chrome 151 profile with the unpacked worktree extension and the real Remarc server on `127.0.0.1:9274`; count established sockets with `lsof`.
- [x] Visit two different secure public origins with content scripts active.
- [x] Assert the real server observes one extension-origin WebSocket, not one connection per tab/origin.
- [x] Assert each page’s `navigator.permissions.query({ name: "loopback-network" })` remains `prompt`, showing no site grant was consumed.
- [ ] Exercise popup connection state, Grab Element, Select Region, shortcut update propagation, highlight dismissal, tab close, worker restart, and app-late-start reconnect.
- [ ] With worker DevTools closed, stop Remarc for more than two minutes, relaunch it without page or popup interaction, and assert the alarm path establishes exactly one socket.
- [ ] Load 0.3.0 in the same profile, keep several pages open, update to this worktree version, and verify/document the required one-time tab reload; ensure no old socket survives after those pages reload.
- [ ] Simulate `runtime.onUpdateAvailable` and verify the current bridge closes without reconnect before the worker reloads.
- [ ] Capture browser-visible evidence that neither origin shows the “Access other apps and services on this device” prompt.

### Review gates

- [x] Adversarially review this plan against its recorded baseline before implementation.
- [x] Re-run the source trace after implementation and confirm all ten invariants.
- [x] Review `git diff --check`, the complete diff, and the exact staged file list before commit.

## Rollout and compatibility

- Existing extension 0.3.0 clients continue to work with the unchanged native multi-client server. Tabs already carrying 0.3.0 must be reloaded once after the extension updates; the new content script installs an explicit teardown hook for future migrations.
- The migrated extension requires Chrome/Chromium 120+ because its disconnected recovery uses 30-second `chrome.alarms` granularity; WebSocket service-worker lifetime support itself began in Chrome 116.
- The patch does not publish an artifact. After merge, release the new extension ZIP, update `website/public/chrome-extension/index.html`, and verify the downloaded archive separately.
- If a properly host-permissioned background worker still receives a per-site LNA prompt in any Chromium browser, retain the source/runtime evidence and file a browser-specific upstream issue rather than restoring page-owned sockets.

## Adversarial review record

Reviewed read-only against baseline `a6d5e9b9745d7b5bea4b5efa4e04ff5af24d42f9` before production edits. The review challenged lifecycle, protocol routing, update, migration, packaging, privacy, security, and verification claims.

- **Resolved blocker:** optional timer-only reconnect contradicted worker suspension and the Chrome 116 minimum. Alarms are now mandatory and the minimum is Chrome 120.
- **Resolved blocker:** the WebSocket keepalive could starve extension updates. An intentional `onUpdateAvailable` shutdown/reload path is now required.
- **Resolved blocker:** tests and `package.json` under `extension/` would ship because the release task copies that directory wholesale. Tests now live under `tests/extension/`, with no package metadata.
- **Resolved blocker:** extension-update recovery overclaimed 0.3.0 behavior. The rollout now explicitly tests and documents the one-time reload requirement.
- **Resolved major:** a worker-owned page-context queue would be lossy on suspension or invasive if persisted. Per-tab memory-only queues remain in content scripts and require delivery acknowledgement.
- **Resolved major:** disconnect highlight cleanup, stale socket callbacks, navigation/document identity, payload validation/size limits, pause-during-capture, popup state coverage, executable runtime evidence, and CI enforcement are now explicit.
- **Quiet areas retained:** extension-origin loopback architecture, one socket per profile, exact native wire envelopes, 250 ms query fallback, shortcut storage fanout, native multi-client backward compatibility, narrow host permission, and no artifact publication in this PR.

The post-implementation adversarial passes then forced the integrated system through deliberately reordered socket, tab, storage, alarm, popup, update, and worker-lifecycle events. They found and closed: a connected-but-closing FIFO loop; same-tab navigation and cold-worker duplicate routing; out-of-order bridge state and stale disconnect cleanup; persisted-Pause fail-open windows; paused `tabActivity` URL leakage; popup injection, Resume propagation, and Retry-button races; alarm creation/update races and swallowed diagnostics; update-drain reconnection; shortcut ordering/default loss; and stale/equal state callbacks within each service-worker session. The final extension suite contains 62 tests.

`delivered: true` means the browser accepted `WebSocket.send`; the native app does not currently acknowledge or deduplicate every page envelope. Exact native receipt would require message IDs plus an ACK/deduplication protocol and remains outside this compatibility fix. Likewise, the loopback transport trusts the local process listening on `127.0.0.1:9274`; authenticated pairing should be evaluated as a separate security change rather than silently expanding this PR.

One theoretical P3 hardening remains: content and popup contexts accept a different worker instance ID as newer, so an unexpectedly delayed lifecycle message from a retired worker could transiently roll state back after a replacement worker reports. This was not reproducible under Chrome's normal single-worker lifecycle and is not a release blocker; retaining retired instance IDs or reconfirming cross-instance changes through `get-connection-state` can be evaluated separately.
