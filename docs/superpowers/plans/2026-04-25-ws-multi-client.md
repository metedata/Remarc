# Multi-Client WebSocket Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Remarc's WebSocket server to handle concurrent connections from multiple browser tabs and windows without evicting them, fixing the "red dot in every tab" bug caused by tabs constantly cancelling each other.

**Architecture:** Replace the single `activeConnection: NWConnection?` slot in `WebSocketService` with a registry keyed by `ObjectIdentifier`, plus a `lastInteractedConnection` field for request/response targeting. Broadcast idempotent config pushes to every client; route request/response messages (`regionQuery`, `dismissRegionHighlight`) only to the connection that last sent us a message. Add explicit per-connection cleanup on terminal receive paths to prevent socket leaks. Add port-injectable start so we can integration-test multi-client behaviour against an ephemeral port without colliding with the running app.

**Tech Stack:** Swift 6, Network.framework (`NWListener`, `NWConnection`, `NWProtocolWebSocket`), Combine, `@MainActor`. Swift Testing (`@Test`, `#expect`) for the test target. Foundation `URLSessionWebSocketTask` for in-test client(s).

**Worktree:** `.worktrees/fix-ws-multi-client` on branch `fix/ws-multi-client` (already created).

**Out of scope (Codex-flagged but separate):**
- Race in `CommentInputWindowController.swift:264-284` between `requestRegionContext` and `consumePendingWebContext`. Pre-existing, unrelated to multi-client.
- `background.js:134-145` `fetch()` health probe creating spurious accepts. Pre-existing, only worth chasing if it shows up in the new logs.
- Migrating the WebSocket from per-tab content scripts to the MV3 background service worker. Bigger architectural change; defer.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift` | Server, connection registry, send routing | Modify |
| `app/RemarcPackage/Tests/RemarcFeatureTests/WebSocketServiceTests.swift` | Multi-client regression tests | Create |

No new types, no file split. The class stays a `@MainActor` singleton; all mutation is main-actor-confined, so the registry needs no extra synchronisation.

---

## Task 1: Make server port-injectable for testing

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift:48-74`

The current `start()` hard-codes `AppConstants.webSocketPort`. Tests can't run alongside the real app (port 9274 is already bound) and can't easily verify multi-client behaviour without a deterministic local server. We add an optional `port` parameter defaulting to the constant. After the listener becomes `.ready`, we expose its actual bound port (matters for tests that pass `port: 0` to ask the OS for an ephemeral port).

- [ ] **Step 1.1: Add a `boundPort` property and a `port`-injectable `start`**

Replace the existing `start()` method (and `ensureStarted` / `retryServer` callers) so production callers pass nothing and tests can pass `port: 0`. Keep the signatures of `ensureStarted()` and `retryServer()` unchanged.

In `WebSocketService.swift`, replace lines 11-13 (the existing `@Published` block) with:

```swift
@Published public private(set) var isRunning = false
@Published public private(set) var isClientConnected = false
@Published public private(set) var serverError: String?
@Published public private(set) var boundPort: UInt16?
```

Replace lines 33-46 (`ensureStarted` and `retryServer`) with:

```swift
public func ensureStarted() {
    if listener == nil && serverError == nil {
        start()
    }
}

public func retryServer() {
    retryCount = 0
    serverError = nil
    listener?.cancel()
    listener = nil
    start()
}
```

(unchanged - keep them; just confirm they stay as-is.)

Replace lines 48-74 (`start()`) with:

```swift
public func start(port: UInt16 = AppConstants.webSocketPort) {
    guard listener == nil else { return }

    let wsOptions = NWProtocolWebSocket.Options()
    let params = NWParameters.tcp
    params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    do {
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        debugLog("WebSocketService: Starting on port \(port)")
    } catch {
        debugLog("WebSocketService: Failed to start - \(error)")
    }
    observeShortcutSettings()
}
```

In `handleListenerState`, update the `.ready` case (line 108) to capture the bound port:

```swift
case .ready:
    isRunning = true
    retryCount = 0
    serverError = nil
    boundPort = listener?.port?.rawValue
    debugLog("WebSocketService: Listening on port \(boundPort ?? 0)")
```

In `stop()` (lines 76-86), add `boundPort = nil` next to the other state resets.

- [ ] **Step 1.2: Build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`

Expected: BUILD SUCCEEDED. No relaunch needed yet - behaviour is unchanged.

- [ ] **Step 1.3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift
git commit -m "refactor(ws): make port injectable for tests, expose boundPort"
```

---

## Task 2: Write failing multi-client test

**Files:**
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/WebSocketServiceTests.swift`

We need a test that fails today and passes after the fix. The test starts the service on an ephemeral port, opens two `URLSessionWebSocketTask` clients, sends a `ping` from each, and asserts both are still alive a beat later. Today, opening the second client cancels the first - the test should observe the first client receiving an unexpected close.

- [ ] **Step 2.1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/WebSocketServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@MainActor
@Suite("WebSocketService multi-client")
struct WebSocketServiceTests {

    /// Wait until `condition` returns true, polling every 50ms, up to `timeout`.
    private func waitFor(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let start = ContinuousClock().now
        while !condition() {
            if ContinuousClock().now - start > timeout { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Start the singleton server on an OS-assigned port, return the bound port.
    private func startOnEphemeralPort() async -> UInt16 {
        let service = WebSocketService.shared
        service.stop()
        service.start(port: 0)
        await waitFor { service.boundPort != nil }
        return service.boundPort ?? 0
    }

    private func makeClient(port: UInt16) -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        return task
    }

    @Test("two simultaneous clients both stay connected")
    func twoClientsCoexist() async throws {
        let port = await startOnEphemeralPort()
        defer { WebSocketService.shared.stop() }

        let clientA = makeClient(port: port)
        let clientB = makeClient(port: port)
        defer {
            clientA.cancel(with: .goingAway, reason: nil)
            clientB.cancel(with: .goingAway, reason: nil)
        }

        // Server reports a client connected once any TCP+WS handshake completes.
        await waitFor { WebSocketService.shared.isClientConnected }
        #expect(WebSocketService.shared.isClientConnected)

        // Send a no-op message from each client and confirm sends complete without error.
        // sendPing() resolves only if the connection is still open; if the server cancelled
        // it, the completion fires with an error.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            clientA.sendPing { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            clientB.sendPing { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    @Test("disconnecting one client leaves others connected")
    func oneClientDisconnectKeepsOthers() async throws {
        let port = await startOnEphemeralPort()
        defer { WebSocketService.shared.stop() }

        let clientA = makeClient(port: port)
        let clientB = makeClient(port: port)
        defer { clientB.cancel(with: .goingAway, reason: nil) }

        await waitFor { WebSocketService.shared.isClientConnected }

        clientA.cancel(with: .goingAway, reason: nil)

        // Give the server time to process the disconnect.
        try? await Task.sleep(for: .milliseconds(300))

        // Server should still report connected because clientB is alive.
        #expect(WebSocketService.shared.isClientConnected)

        // clientB ping must still succeed.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            clientB.sendPing { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
```

- [ ] **Step 2.2: Run the test - confirm it fails**

Run: `cd app/RemarcPackage && swift test --filter WebSocketServiceTests 2>&1 | tail -40`

Expected: at least one test FAILS. The most likely failure is `twoClientsCoexist` - either `clientA.sendPing` reports an error (its connection was cancelled by the server when `clientB` arrived) or the second test's `clientB` ping fails for the same reason. If both pass on this commit, stop and reinvestigate - the diagnosis was wrong or the test isn't exercising the bug.

- [ ] **Step 2.3: Commit the failing test**

```bash
git add app/RemarcPackage/Tests/RemarcFeatureTests/WebSocketServiceTests.swift
git commit -m "test(ws): add failing multi-client regression test"
```

---

## Task 3: Replace single-slot connection with a registry

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift`

This is the core fix. Replace `activeConnection: NWConnection?` with `connections: [ObjectIdentifier: NWConnection]` plus a `lastInteractedConnection: NWConnection?` for request/response targeting. Stop cancelling prior connections in `handleNewConnection`. Remove from the registry on `.cancelled` / `.failed`. Cancel on terminal receive errors so leaks don't reaccumulate. Drop the connection identity into the receive callback via `[weak connection]` so cleanup keys don't go stale.

- [ ] **Step 3.1: Replace storage and `handleNewConnection`**

In `WebSocketService.swift`, replace line 21 (`private var activeConnection: NWConnection?`) with:

```swift
private var connections: [ObjectIdentifier: NWConnection] = [:]
/// Connection that most recently sent a message. Used to route request/response
/// messages (regionQuery, dismissRegionHighlight) back to the tab that initiated.
private var lastInteractedConnection: NWConnection?
```

Replace `handleNewConnection` (lines 136-164) with:

```swift
private func handleNewConnection(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    connections[id] = connection

    connection.stateUpdateHandler = { [weak self, weak connection] state in
        Task { @MainActor in
            guard let self, let connection else { return }
            let id = ObjectIdentifier(connection)
            switch state {
            case .ready:
                self.isClientConnected = !self.connections.isEmpty
                SettingsManager.shared.hasExtensionEverConnected = true
                debugLog("WebSocketService: Client connected (\(self.connections.count) total)")
                self.sendShortcutConfig(to: connection)
            case .failed(let error):
                self.removeConnection(id: id, connection: connection)
                debugLog("WebSocketService: Connection failed - \(error)")
            case .cancelled:
                self.removeConnection(id: id, connection: connection)
                debugLog("WebSocketService: Client disconnected (\(self.connections.count) total)")
            default:
                break
            }
        }
    }

    connection.start(queue: .main)
    receiveMessage(on: connection)
}

private func removeConnection(id: ObjectIdentifier, connection: NWConnection) {
    connections.removeValue(forKey: id)
    if lastInteractedConnection === connection {
        lastInteractedConnection = nil
    }
    isClientConnected = !connections.isEmpty
}
```

- [ ] **Step 3.2: Update `receiveMessage` to track last interaction and clean up on terminal errors**

Replace `receiveMessage` (lines 168-185) with:

```swift
private func receiveMessage(on connection: NWConnection) {
    connection.receiveMessage { [weak self, weak connection] content, _, _, error in
        Task { @MainActor in
            guard let self, let connection else { return }
            if let error {
                debugLog("WebSocketService: Receive error - \(error)")
                connection.cancel()
                return
            }
            if let data = content {
                self.lastInteractedConnection = connection
                self.processMessage(data)
            }
            if connection.state == .ready {
                self.receiveMessage(on: connection)
            }
        }
    }
}
```

The change: explicit `connection.cancel()` on receive error guarantees the state handler fires `.cancelled` and we remove the connection from the registry, even when the underlying socket has died in a way that wouldn't otherwise trigger a state transition. This is what plugs the `CLOSE_WAIT` leak.

- [ ] **Step 3.3: Update `stop()` to cancel all connections**

Replace `stop()` (lines 76-86) with:

```swift
public func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values {
        connection.cancel()
    }
    connections.removeAll()
    lastInteractedConnection = nil
    regionRectFallbackTask?.cancel()
    regionRectFallbackTask = nil
    isRunning = false
    isClientConnected = false
    boundPort = nil
    debugLog("WebSocketService: Stopped")
}
```

- [ ] **Step 3.4: Build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`

Expected: BUILD SUCCEEDED. There will be compile errors in the existing `requestRegionContext`, `dismissRegionHighlight`, and `sendShortcutConfig` methods because they reference `activeConnection`. We fix those in Task 4.

If the build fails on those specific call sites only, that is expected; proceed to Task 4 immediately. If there are other errors, stop and investigate.

---

## Task 4: Route outbound messages correctly

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift`

Three outbound methods reference the now-deleted `activeConnection`. Each has a different correct routing behaviour:

- `sendShortcutConfig`: idempotent config push. Broadcast to all connections (so every tab gets shortcuts), but also support a single-connection variant for the on-connect handshake (called from `handleNewConnection` `.ready` case in Task 3).
- `requestRegionContext`: response to a `regionRect` from a specific tab. Send only to `lastInteractedConnection`.
- `dismissRegionHighlight`: clears the region highlight on the tab that has it. Send only to `lastInteractedConnection`.

- [ ] **Step 4.1: Add a private `send(_:on:)` helper**

In `WebSocketService.swift`, add this private helper near the other `// MARK: - Send Messages to Extension` block (above `requestRegionContext`):

```swift
private func send(_ payload: [String: Any], identifier: String, on connection: NWConnection) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: identifier, metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
}
```

- [ ] **Step 4.2: Update `requestRegionContext` to target the last-interacted connection**

Replace `requestRegionContext` (lines 300-318) with:

```swift
public func requestRegionContext(screenX: CGFloat, screenY: CGFloat, width: CGFloat, height: CGFloat) {
    guard let connection = lastInteractedConnection else { return }
    let payload: [String: Any] = [
        "type": "regionQuery",
        "data": [
            "screenX": screenX,
            "screenY": screenY,
            "width": width,
            "height": height
        ]
    ]
    send(payload, identifier: "regionQuery", on: connection)
}
```

- [ ] **Step 4.3: Update `dismissRegionHighlight` to target the last-interacted connection**

Replace `dismissRegionHighlight` (lines 320-333) with:

```swift
public func dismissRegionHighlight() {
    guard let connection = lastInteractedConnection else { return }
    let payload: [String: Any] = [
        "type": "dismissRegionHighlight",
        "data": [String: Any]()
    ]
    send(payload, identifier: "dismissRegionHighlight", on: connection)
}
```

- [ ] **Step 4.4: Update `sendShortcutConfig` to broadcast (and support single-target)**

Replace `sendShortcutConfig` (lines 335-359) with:

```swift
public func sendShortcutConfig(to specificConnection: NWConnection? = nil) {
    let settings = SettingsManager.shared
    let payload: [String: Any] = [
        "type": "shortcutConfig",
        "data": [
            "grab-element": [
                "key": settings.extensionGrabElementShortcut.key,
                "modifiers": settings.extensionGrabElementShortcut.modifiers,
            ],
            "region-select": [
                "key": settings.extensionRegionSelectShortcut.key,
                "modifiers": settings.extensionRegionSelectShortcut.modifiers,
            ],
        ]
    ]

    let targets = specificConnection.map { [$0] } ?? Array(connections.values)
    guard !targets.isEmpty else { return }

    for connection in targets {
        send(payload, identifier: "shortcutConfig", on: connection)
    }
    debugLog("WebSocketService: Sent shortcut config to \(targets.count) client(s)")
}
```

- [ ] **Step 4.5: Build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4.6: Run the multi-client tests - confirm both pass**

Run: `cd app/RemarcPackage && swift test --filter WebSocketServiceTests 2>&1 | tail -40`

Expected: both tests PASS. If either fails, stop and re-read the test failure - do NOT add more fixes on top. Likely culprits if it fails: a connection state transition arriving out of order (revisit Step 3.1 ordering of `removeConnection` vs `isClientConnected` updates) or `boundPort` not being set before clients try to connect (revisit Step 1.1).

- [ ] **Step 4.7: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift
git commit -m "fix(ws): support multiple concurrent extension clients

Replace single activeConnection slot with a registry keyed by
ObjectIdentifier, plus lastInteractedConnection for request/response
targeting. Broadcast shortcut config to all tabs; route regionQuery and
dismissRegionHighlight only to the connection that initiated. Cancel on
terminal receive errors to plug the CLOSE_WAIT leak that the previous
eviction-on-new-connection design produced under multi-tab churn.

Fixes the 'red dot in every tab' bug: each browser tab opens its own
WebSocket from content.js; the previous single-slot server cancelled the
prior connection on every new arrival, causing tabs to mutually evict
each other in a loop."
```

---

## Task 5: Manual integration test against the real Chrome extension

**Files:** none (verification only)

Tests prove the server logic. The user-facing fix needs verification through the actual extension, since the bug only manifests with multiple Chromium tabs running the content script.

- [ ] **Step 5.1: Stop the currently-running Remarc**

The currently-running app is from `.worktrees/design-md-canonical/` (a different worktree's build). Quit it before launching the fix.

Run: `pkill -x Remarc; sleep 0.5`

- [ ] **Step 5.2: Build and launch the fixed app**

Run from the `.worktrees/fix-ws-multi-client` worktree root:

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" && pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Expected: BUILD SUCCEEDED, Remarc menu-bar icon appears.

- [ ] **Step 5.3: Verify multi-tab badge stays green**

In your browser:
1. Open three tabs to different non-`chrome://` sites (e.g. github.com, news.ycombinator.com, example.com).
2. Wait ~5 seconds for content scripts to connect.
3. Click each tab in turn. The toolbar badge should show a green dot in every tab.
4. Reload one tab. Its badge should briefly flicker (during reconnect) but the OTHER tabs' badges must NOT change. (Pre-fix: reloading one tab kicked the others off the server.)

If any tab still shows red, stop. Re-read the Mac log: `tail -f /tmp/remarc_debug.log`. The expected pattern is one `Client connected (N total)` line per tab and no `Client disconnected` flurries. If you see disconnect storms, the fix didn't take effect or a different bug is at play - investigate before claiming the work done.

- [ ] **Step 5.4: Verify region-select still works in the active tab**

In a single tab, use the region-select shortcut (Alt+Shift+R by default). Draw a region. Confirm the comment input panel appears with web context attached. Repeat in a different tab. Both should work.

This proves the `lastInteractedConnection` routing is correct: each `regionRect` updates `lastInteractedConnection` to the originating tab, and the subsequent `requestRegionContext` and `dismissRegionHighlight` go back to that same tab rather than to all tabs (which would race) or to a stale tab.

- [ ] **Step 5.5: Verify the CLOSE_WAIT leak is gone**

After the multi-tab test has been running for ~30 seconds:

```bash
lsof -nP -iTCP:9274 | grep -c CLOSE_WAIT
```

Expected: 0 (or at most 1-2 transient ones). Pre-fix this was 14+. If still elevated, the explicit `connection.cancel()` on receive-error path (Step 3.2) isn't firing in some path - investigate.

- [ ] **Step 5.6: Commit any verification notes if needed**

No code changes; nothing to commit unless Step 5.3-5.5 turned up follow-ups worth recording.

---

## Self-review summary

- **Spec coverage:** All five Codex review points addressed:
  1. Multi-connection registry (root cause fix) - Task 3.
  2. No naive broadcast - request/response messages route to `lastInteractedConnection`, only `sendShortcutConfig` broadcasts - Task 4.
  3. Service-worker migration deliberately deferred - documented in "Out of scope".
  4. Explicit `connection.cancel()` on terminal receive error - Step 3.2.
  5. Other Codex-flagged issues (region-context race, fetch probe) explicitly out of scope with rationale.
- **Type/name consistency:** `connections`, `lastInteractedConnection`, `removeConnection(id:connection:)`, `send(_:identifier:on:)`, `boundPort` - used identically in every reference.
- **Placeholder scan:** every step has actual code or an exact command. No "add appropriate handling" or "similar to X" lines.
