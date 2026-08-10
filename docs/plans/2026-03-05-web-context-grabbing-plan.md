# Web Context Grabbing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Chrome extension + WebSocket integration so Remarc can capture React component metadata (name, file path, hierarchy, HTML) when commenting on web content.

**Architecture:** Chrome extension (content script in MAIN world reads React fiber tree, ISOLATED world script holds WebSocket to Remarc). Remarc runs an NWListener WebSocket server on localhost. New `WebContext` struct attaches to any comment type. New `.webElement` CommentType for element-level grabs.

**Tech Stack:** Swift (Network framework for WebSocket), JavaScript (Chrome Manifest V3 extension), React DevTools hook (`__REACT_DEVTOOLS_GLOBAL_HOOK__` via injected main-world script)

**Design doc:** `docs/plans/2026-03-05-web-context-grabbing-design.md`

---

## Phase 1: Data Model

### Task 1: Create WebContext Model

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Models/WebContext.swift`

**Step 1: Create WebContext struct**

```swift
import Foundation

public struct WebContext: Codable, Equatable, Sendable {
    public var componentName: String?
    public var filePath: String?
    public var hierarchy: String?
    public var elementHTML: String?

    public init(
        componentName: String? = nil,
        filePath: String? = nil,
        hierarchy: String? = nil,
        elementHTML: String? = nil
    ) {
        self.componentName = componentName
        self.filePath = filePath
        self.hierarchy = hierarchy
        self.elementHTML = elementHTML
    }

    /// Human-readable summary for display in comment cards.
    /// Example: "LoginForm . login-form.tsx:46"
    public var displaySummary: String? {
        let parts = [componentName, filePath].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
```

**Step 2: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/WebContext.swift
git commit -m "feat: add WebContext model for web element metadata"
```

---

### Task 2: Add .webElement to CommentType

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentType.swift`

**Step 1: Add the new case and update all switch statements**

Add after line 7 (after `case critMode`):
```swift
case webElement(componentName: String?, filePath: String?)
```

Update `displayText` (line 9-16) — add before closing brace:
```swift
case .webElement(let name, _): return name
```

Update `isQuickNote`, `isScreenshot`, `isCritMode` — no change needed (new case returns false implicitly since they use `if case`).

Add new convenience:
```swift
public var isWebElement: Bool {
    if case .webElement = self { return true }
    return false
}
```

Update `imagePath` — add before closing brace:
```swift
// .webElement has no image — no change needed, default nil
```

Update `identifier` (line 40-47):
```swift
case .webElement: return "webElement"
```

Update `displayName` (line 49-56):
```swift
case .webElement: return "Web Element"
```

Update `iconName` (line 58-65):
```swift
case .webElement: return "chevron.left.forwardslash.chevron.right"
```

**Step 2: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: Build will FAIL — switch statements in other files are not exhaustive. That's expected; we'll fix them in the next tasks.

**Step 3: Commit (partial — will fix exhaustiveness next)**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/CommentType.swift
git commit -m "feat: add .webElement case to CommentType"
```

---

### Task 3: Add webContext to Comment + Fix All Switch Exhaustiveness

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Add webContext property to Comment**

In `Comment.swift`, add after `attachments` (line 18):
```swift
public var webContext: WebContext?
```

Update `init` — add parameter after `attachments` (line 35):
```swift
webContext: WebContext? = nil
```

Add in init body after `self.attachments = attachments`:
```swift
self.webContext = webContext
```

Update `truncatedTypeLabel` switch (line 77-91) — add case:
```swift
case .webElement(let name, let path):
    let parts = [name, path].compactMap { $0 }
    return parts.isEmpty ? "Web Element" : parts.joined(separator: " \u{00B7} ")
```

**Step 2: Fix CommentCardView switch**

In `CommentCardView.swift` `referenceView` (line 75), change line 128:
```swift
case .quickNote, .critMode:
```
to:
```swift
case .quickNote, .critMode, .webElement:
```

This is the minimal fix. We'll add proper web element display in Phase 5 (UI task).

**Step 3: Fix HistoryCardView switch**

In `HistoryCardView.swift` `referenceView` (line 46), change line 70:
```swift
case .quickNote, .critMode:
```
to:
```swift
case .quickNote, .critMode, .webElement:
```

Same as above — minimal fix now, proper display in Phase 5.

**Step 4: Fix ExportManager formatReference switch**

In `ExportManager.swift` `formatReference` (line 29), add before closing brace (after line 47):
```swift
case .webElement(let name, let path):
    let parts = [name, path].compactMap { $0 }
    let label = parts.isEmpty ? "Web Element" : parts.joined(separator: " \u{00B7} ")
    switch style {
    case .blockquote: return "> [\(label)]"
    case .rePrefix: return "Re: \(label)"
    case .quoted: return "\"\(label)\""
    }
```

**Step 5: Fix ExportManager JSON export**

In `ExportManager.swift` `jsonForSession` (line 237), add to `ExportComment` struct after `attachments` (line 246):
```swift
let webContext: WebContext?
```

Update the mapping (line 257-266), add after `attachments` line:
```swift
webContext: comment.webContext
```

**Step 6: Update PersistenceManager.createComment**

In `PersistenceManager.swift` line 241, add `webContext` parameter:
```swift
public func createComment(type: CommentType, commentText: String, source: String, appBundleID: String?, attachments: [String] = [], webContext: WebContext? = nil) -> Comment?
```

Update the Comment initializer call (line 255-262), add:
```swift
webContext: webContext
```

**Step 7: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift \
        app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift \
        app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift
git commit -m "feat: add webContext to Comment, fix switch exhaustiveness for .webElement"
```

---

## Phase 2: WebSocket Server

### Task 4: Add WebSocket Constants

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

**Step 1: Add WebSocket constants to AppConstants**

After line 91 (before closing brace), add:
```swift
// WebSocket server
public static let webSocketPort: UInt16 = 9274
public static let webSocketHost = "127.0.0.1"
```

**Step 2: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift
git commit -m "feat: add WebSocket server constants"
```

---

### Task 5: Create WebSocketService

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift`

**Step 1: Implement the WebSocket server**

Uses Apple's Network framework (`NWListener` + `NWProtocolWebSocket`). No third-party dependencies.

```swift
import Foundation
import Network

/// Lightweight WebSocket server on localhost for receiving web context from the Chrome extension.
@MainActor
public final class WebSocketService: ObservableObject {
    public static let shared = WebSocketService()

    @Published public private(set) var isRunning = false
    @Published public private(set) var isClientConnected = false

    /// Most recent web context received from the extension (consumed on next comment creation).
    @Published public var pendingWebContext: WebContext?

    private var listener: NWListener?
    private var activeConnection: NWConnection?

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        guard listener == nil else { return }

        let wsOptions = NWProtocolWebSocket.Options()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: AppConstants.webSocketPort)!)
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
            debugLog("WebSocketService: Starting on port \(AppConstants.webSocketPort)")
        } catch {
            debugLog("WebSocketService: Failed to start — \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
        isRunning = false
        isClientConnected = false
        debugLog("WebSocketService: Stopped")
    }

    // MARK: - Pending Context

    /// Consume and return the pending web context, clearing it.
    public func consumePendingWebContext() -> WebContext? {
        let context = pendingWebContext
        pendingWebContext = nil
        return context
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            debugLog("WebSocketService: Listening on port \(AppConstants.webSocketPort)")
        case .failed(let error):
            isRunning = false
            debugLog("WebSocketService: Listener failed — \(error)")
            // Retry after a delay
            listener = nil
            Task {
                try? await Task.sleep(for: .seconds(3))
                start()
            }
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Replace existing connection (only one extension client expected)
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isClientConnected = true
                    debugLog("WebSocketService: Client connected")
                case .failed(let error):
                    self?.isClientConnected = false
                    self?.activeConnection = nil
                    debugLog("WebSocketService: Connection failed — \(error)")
                case .cancelled:
                    self?.isClientConnected = false
                    self?.activeConnection = nil
                    debugLog("WebSocketService: Client disconnected")
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
        receiveMessage(on: connection)
    }

    // MARK: - Message Handling

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            Task { @MainActor in
                if let error = error {
                    debugLog("WebSocketService: Receive error — \(error)")
                    return
                }

                if let data = content {
                    self?.processMessage(data)
                }

                // Continue receiving
                if connection.state == .ready {
                    self?.receiveMessage(on: connection)
                }
            }
        }
    }

    private func processMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let payload = json["data"] as? [String: Any]
        else {
            debugLog("WebSocketService: Invalid message")
            return
        }

        switch type {
        case "selectionContext", "elementGrab":
            let context = WebContext(
                componentName: payload["componentName"] as? String,
                filePath: payload["filePath"] as? String,
                hierarchy: payload["hierarchy"] as? String,
                elementHTML: payload["elementHTML"] as? String
            )
            pendingWebContext = context
            debugLog("WebSocketService: Received \(type) — \(context.displaySummary ?? "no summary")")

            if type == "elementGrab" {
                NotificationCenter.default.post(
                    name: .webElementGrabbed,
                    object: nil,
                    userInfo: ["webContext": context]
                )
            }

        case "regionContext":
            // For screenshot enrichment — store the first element's context
            if let elements = payload["elements"] as? [[String: Any]], let first = elements.first {
                let context = WebContext(
                    componentName: first["componentName"] as? String,
                    filePath: first["filePath"] as? String,
                    hierarchy: first["hierarchy"] as? String,
                    elementHTML: first["elementHTML"] as? String
                )
                pendingWebContext = context
                debugLog("WebSocketService: Received regionContext with \(elements.count) elements")
            }

        default:
            debugLog("WebSocketService: Unknown message type '\(type)'")
        }
    }

    // MARK: - Send Messages to Extension

    /// Ask the extension what elements are at the given screen coordinates (for screenshot enrichment).
    public func requestRegionContext(screenX: CGFloat, screenY: CGFloat, width: CGFloat, height: CGFloat) {
        let message: [String: Any] = [
            "type": "regionQuery",
            "data": [
                "screenX": screenX,
                "screenY": screenY,
                "width": width,
                "height": height
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let connection = activeConnection
        else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "regionQuery", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

// MARK: - Notification

extension Notification.Name {
    public static let webElementGrabbed = Notification.Name("webElementGrabbed")
}
```

**Step 2: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift
git commit -m "feat: add WebSocketService for Chrome extension communication"
```

---

### Task 6: Start WebSocket Server on App Launch

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/AppController.swift` (or wherever the app initializes services)

**Step 1: Find where services are started**

Search for where `SelectionMonitor.shared.startMonitoring()` is called — the WebSocket server should start alongside it.

**Step 2: Add WebSocketService.shared.start()**

Add next to the existing service startups:
```swift
WebSocketService.shared.start()
```

**Step 3: Verify build + relaunch**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Then: `bash scripts/relaunch.sh`
Verify in `/tmp/remarc_debug.log` that you see "WebSocketService: Listening on port 9274"

**Step 4: Commit**

```bash
git add <modified-file>
git commit -m "feat: start WebSocket server on app launch"
```

---

## Phase 3: Integration — Enriching Existing Flows

### Task 7: Enrich Text Selections with Web Context

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

**Step 1: Add Chromium bundle ID list**

In `Constants.swift`, add to `AppConstants`:
```swift
// Known Chromium browser bundle IDs
public static let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "company.thebrowser.Browser",   // Arc
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
]
```

**Step 2: Attach web context when saving comments from Chromium browsers**

In `CommentInputWindowController.swift`, in the `saveComment` method (around line 290), before the `createComment` call:

```swift
// Attach web context if the selection came from a Chromium browser
let webContext: WebContext? = {
    if let bundleID = selection?.appBundleID,
       AppConstants.chromiumBundleIDs.contains(bundleID) {
        return WebSocketService.shared.consumePendingWebContext()
    }
    return nil
}()
```

Update the createComment call (line 290-296) to pass webContext:
```swift
let comment = PersistenceManager.shared.createComment(
    type: type,
    commentText: text,
    source: source,
    appBundleID: selection?.appBundleID,
    attachments: attachments,
    webContext: webContext
)
```

**Step 3: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift \
        app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift
git commit -m "feat: enrich text selection comments with web context from Chromium"
```

---

### Task 8: Enrich Screenshots with Web Context

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

**Step 1: Track the pre-screenshot frontmost app**

In CommentInputWindowController, when screenshot mode begins (around `showForScreenshot`), capture the frontmost app's bundle ID. This may already be available — check if `currentSelection?.appBundleID` is set at screenshot time.

If not, add a property:
```swift
private var screenshotSourceBundleID: String?
```

Set it when entering screenshot mode:
```swift
screenshotSourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
```

**Step 2: Request region context and attach to screenshot comment**

In the screenshot save flow (around lines 229-246 and 249-267), before calling `createComment`, check if the source was Chromium and consume pending context:

```swift
let webContext: WebContext? = {
    if let bundleID = screenshotSourceBundleID,
       AppConstants.chromiumBundleIDs.contains(bundleID) {
        return WebSocketService.shared.consumePendingWebContext()
    }
    return nil
}()
```

Pass it to both createComment calls:
```swift
let comment = PersistenceManager.shared.createComment(
    type: type,
    commentText: commentText,
    source: "Screenshot",
    appBundleID: screenshotSourceBundleID,
    attachments: savedAttachments,
    webContext: webContext
)
```

**Step 3: Optionally request region context from extension**

After the user finishes selecting the screenshot region (in `handleRegionSelected` callback), if the source is Chromium, request context:

```swift
if let bundleID = screenshotSourceBundleID,
   AppConstants.chromiumBundleIDs.contains(bundleID) {
    WebSocketService.shared.requestRegionContext(
        screenX: captureRect.origin.x,
        screenY: captureRect.origin.y,
        width: captureRect.width,
        height: captureRect.height
    )
}
```

The extension responds asynchronously; the `pendingWebContext` will be set by the time the user finishes typing and saves.

**Step 4: Verify build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: enrich screenshot comments with web context from Chromium"
```

---

### Task 9: Handle Element Grab from Extension

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift` (or `AppController.swift`)

**Step 1: Listen for element grab notifications**

The WebSocketService posts `.webElementGrabbed` when an element grab arrives. Add a listener that creates a comment input for it:

```swift
NotificationCenter.default.addObserver(
    forName: .webElementGrabbed,
    object: nil,
    queue: .main
) { [weak self] notification in
    guard let context = notification.userInfo?["webContext"] as? WebContext else { return }
    self?.showForWebElement(context)
}
```

**Step 2: Add showForWebElement method**

```swift
func showForWebElement(_ context: WebContext) {
    let type = CommentType.webElement(
        componentName: context.componentName,
        filePath: context.filePath
    )
    // Show the comment input panel positioned near the menu bar
    // (no selection rect — similar to quick note positioning)
    showForGrab(type: type, webContext: context)
}
```

The exact positioning depends on how the existing `showStandaloneNote` works — use a similar approach.

**Step 3: Verify build + relaunch**

Run build and relaunch to test.

**Step 4: Commit**

```bash
git add <modified-files>
git commit -m "feat: handle element grab from Chrome extension"
```

---

## Phase 4: UI Updates

### Task 10: Web Element Display in Comment Cards

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift`

**Step 1: Update CommentCardView referenceView**

Replace the placeholder `case .webElement` (currently grouped with quickNote/critMode) with proper display:

```swift
case .webElement(let name, let path):
    VStack(alignment: .leading, spacing: 2) {
        if let name = name {
            Text(name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
        if let path = path {
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.6))
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 8)
    .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
            .frame(width: 2)
    }
    .contentShape(Rectangle())
    .onTapGesture {
        FloatingEditorController.shared.showForEdit(comment: comment)
    }
```

**Step 2: Add web context badge to all comment types**

Below the existing `referenceView` in the card body, add a conditional web context badge:

```swift
if let summary = comment.webContext?.displaySummary {
    Text(summary)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.45))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 10)
}
```

This shows the web context badge on `.comment(text:)` and `.screenshot` types when they were captured from a browser.

**Step 3: Update HistoryCardView similarly**

Apply the same pattern to `HistoryCardView.referenceView` — replace `.webElement` case and add web context badge.

**Step 4: Verify build + relaunch**

Run build and relaunch. Verify the cards display correctly.

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift
git commit -m "feat: display web context in comment and history cards"
```

---

## Phase 5: Chrome Extension

### Task 11: Extension Scaffold

**Files:**
- Create: `extension/manifest.json`
- Create: `extension/main-world.js`
- Create: `extension/content.js`
- Create: `extension/icons/` (placeholder)

**Step 1: Create manifest.json**

```json
{
  "manifest_version": 3,
  "name": "Remarc Web Context",
  "version": "0.1.0",
  "description": "Captures web element context for Remarc comments",
  "permissions": ["activeTab"],
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["main-world.js"],
      "run_at": "document_start",
      "world": "MAIN"
    },
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_start",
      "world": "ISOLATED"
    }
  ],
  "commands": {
    "grab-element": {
      "suggested_key": {
        "default": "Ctrl+Shift+G",
        "mac": "Command+Shift+G"
      },
      "description": "Grab web element context"
    }
  },
  "icons": {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  }
}
```

**Step 2: Commit scaffold**

```bash
git add extension/
git commit -m "feat: scaffold Chrome extension for Remarc web context"
```

---

### Task 12: Main-World Script (React Fiber Access)

**Files:**
- Modify: `extension/main-world.js`

**Step 1: Implement React hook registration + fiber walking**

```javascript
// main-world.js — runs in the page's JS context (MAIN world)
// Registers a React DevTools hook and provides fiber tree access.

(function () {
  "use strict";

  // Register DevTools hook BEFORE React loads (document_start ensures this)
  if (!window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      renderers: new Map(),
      supportsFiber: true,
      inject(renderer) {
        const id = this.renderers.size + 1;
        this.renderers.set(id, renderer);
        return id;
      },
      onCommitFiberRoot() {},
      onCommitFiberUnmount() {},
    };
  }

  // Fiber access utilities
  function getFiberFromElement(element) {
    const keys = Object.keys(element);
    const fiberKey = keys.find(
      (k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$")
    );
    return fiberKey ? element[fiberKey] : null;
  }

  function getComponentName(fiber) {
    if (!fiber || !fiber.type) return null;
    if (typeof fiber.type === "string") return null; // HTML element
    return fiber.type.displayName || fiber.type.name || null;
  }

  function getSourceLocation(fiber) {
    if (!fiber || !fiber._debugSource) return null;
    const src = fiber._debugSource;
    const file = src.fileName || "";
    const line = src.lineNumber || "";
    const col = src.columnNumber || "";
    return line ? `${file}:${line}${col ? ":" + col : ""}` : file;
  }

  function walkFiberTree(element) {
    let fiber = getFiberFromElement(element);
    if (!fiber) return null;

    const hierarchy = [];
    let componentName = null;
    let filePath = null;
    let current = fiber;

    while (current) {
      const name = getComponentName(current);
      if (name) {
        hierarchy.unshift(name);
        if (!componentName) {
          componentName = name;
          filePath = getSourceLocation(current);
        }
      }
      current = current.return;
    }

    return {
      componentName,
      filePath,
      hierarchy: hierarchy.join(" > "),
      elementHTML: element.outerHTML?.substring(0, 2000), // Cap at 2KB
    };
  }

  // Expose to content script via postMessage
  window.addEventListener("message", (event) => {
    if (event.source !== window) return;

    if (event.data?.type === "__REMARC_GET_CONTEXT__") {
      const { selector, x, y } = event.data;
      let element;

      if (selector) {
        element = document.querySelector(selector);
      } else if (x !== undefined && y !== undefined) {
        element = document.elementFromPoint(x, y);
      }

      if (!element) {
        window.postMessage({ type: "__REMARC_CONTEXT_RESULT__", data: null }, "*");
        return;
      }

      const result = walkFiberTree(element);
      if (!result) {
        // No React fiber — fall back to plain HTML context
        window.postMessage({
          type: "__REMARC_CONTEXT_RESULT__",
          data: {
            componentName: null,
            filePath: null,
            hierarchy: null,
            elementHTML: element.outerHTML?.substring(0, 2000),
          },
        }, "*");
        return;
      }

      window.postMessage({ type: "__REMARC_CONTEXT_RESULT__", data: result }, "*");
    }
  });
})();
```

**Step 2: Commit**

```bash
git add extension/main-world.js
git commit -m "feat: main-world script for React fiber tree access"
```

---

### Task 13: Isolated Content Script (WebSocket + Selection + Element Grab)

**Files:**
- Modify: `extension/content.js`

**Step 1: Implement the content script**

```javascript
// content.js — runs in ISOLATED world
// Holds WebSocket connection to Remarc, handles selection enrichment and element grab.

(function () {
  "use strict";

  const REMARC_WS_URL = "ws://127.0.0.1:9274";
  const SELECTION_DEBOUNCE_MS = 200;

  let ws = null;
  let grabModeActive = false;
  let highlightOverlay = null;

  // --- WebSocket Connection ---

  function connect() {
    if (ws && ws.readyState <= WebSocket.OPEN) return;

    try {
      ws = new WebSocket(REMARC_WS_URL);

      ws.onopen = () => console.log("[Remarc] Connected to Remarc");

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === "regionQuery") {
            handleRegionQuery(msg.data);
          }
        } catch (e) {
          console.error("[Remarc] Bad message:", e);
        }
      };

      ws.onclose = () => {
        ws = null;
        // Reconnect after delay
        setTimeout(connect, 3000);
      };

      ws.onerror = () => {
        ws?.close();
      };
    } catch (e) {
      setTimeout(connect, 3000);
    }
  }

  function send(type, data) {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type, data }));
    }
  }

  // --- Context Retrieval (via main-world script) ---

  function getContextForElement(opts) {
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        window.removeEventListener("message", handler);
        resolve(null);
      }, 500);

      function handler(event) {
        if (event.data?.type === "__REMARC_CONTEXT_RESULT__") {
          clearTimeout(timeout);
          window.removeEventListener("message", handler);
          resolve(event.data.data);
        }
      }

      window.addEventListener("message", handler);
      window.postMessage({ type: "__REMARC_GET_CONTEXT__", ...opts }, "*");
    });
  }

  // --- Selection Enrichment ---

  let selectionTimer = null;

  document.addEventListener("selectionchange", () => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(handleSelectionChange, SELECTION_DEBOUNCE_MS);
  });

  async function handleSelectionChange() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;

    const range = selection.getRangeAt(0);
    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer
      : range.startContainer.parentElement;

    if (!element) return;

    const rect = range.getBoundingClientRect();
    const context = await getContextForElement({
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
    });

    if (context) {
      send("selectionContext", context);
    }
  }

  // --- Element Grab Mode ---

  function enterGrabMode() {
    if (grabModeActive) return;
    grabModeActive = true;

    // Create highlight overlay
    highlightOverlay = document.createElement("div");
    highlightOverlay.id = "__remarc-grab-overlay__";
    Object.assign(highlightOverlay.style, {
      position: "fixed",
      pointerEvents: "none",
      border: "2px solid #6366f1",
      borderRadius: "4px",
      backgroundColor: "rgba(99, 102, 241, 0.1)",
      zIndex: "2147483647",
      display: "none",
      transition: "all 0.05s ease-out",
    });
    document.documentElement.appendChild(highlightOverlay);

    document.addEventListener("mousemove", grabMouseMove, true);
    document.addEventListener("click", grabClick, true);
    document.addEventListener("keydown", grabKeyDown, true);
  }

  function exitGrabMode() {
    grabModeActive = false;
    highlightOverlay?.remove();
    highlightOverlay = null;
    document.removeEventListener("mousemove", grabMouseMove, true);
    document.removeEventListener("click", grabClick, true);
    document.removeEventListener("keydown", grabKeyDown, true);
  }

  function grabMouseMove(e) {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === highlightOverlay) return;

    const rect = el.getBoundingClientRect();
    Object.assign(highlightOverlay.style, {
      display: "block",
      left: rect.left + "px",
      top: rect.top + "px",
      width: rect.width + "px",
      height: rect.height + "px",
    });
  }

  async function grabClick(e) {
    e.preventDefault();
    e.stopPropagation();

    const context = await getContextForElement({
      x: e.clientX,
      y: e.clientY,
    });

    if (context) {
      send("elementGrab", context);
    }

    exitGrabMode();
  }

  function grabKeyDown(e) {
    if (e.key === "Escape") {
      exitGrabMode();
    }
  }

  // Listen for grab command from keyboard shortcut
  // (MV3 commands are dispatched to the background service worker,
  //  which forwards to content script via chrome.tabs.sendMessage)
  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener((msg) => {
      if (msg.type === "grab-element") {
        enterGrabMode();
      }
    });
  }

  // --- Region Query (screenshot enrichment) ---

  async function handleRegionQuery(data) {
    const { screenX, screenY, width, height } = data;

    // Convert screen coords to viewport coords
    // screenX/Y from macOS, window.screenX/Y from browser
    const vpX = screenX - window.screenX;
    const vpY = screenY - window.screenY;

    // Sample center point (simplified — could sample multiple points)
    const centerX = vpX + width / 2;
    const centerY = vpY + height / 2;

    const context = await getContextForElement({ x: centerX, y: centerY });
    if (context) {
      send("regionContext", { elements: [context] });
    }
  }

  // --- Init ---
  connect();
})();
```

**Step 2: Commit**

```bash
git add extension/content.js
git commit -m "feat: content script with WebSocket, selection enrichment, and element grab"
```

---

### Task 14: Background Service Worker (Keyboard Shortcut Forwarding)

**Files:**
- Create: `extension/background.js`
- Modify: `extension/manifest.json`

**Step 1: Create background.js**

```javascript
// background.js — MV3 service worker
// Forwards keyboard shortcut commands to the active tab's content script.

chrome.commands.onCommand.addListener(async (command) => {
  if (command === "grab-element") {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab?.id) {
      chrome.tabs.sendMessage(tab.id, { type: "grab-element" });
    }
  }
});
```

**Step 2: Add background to manifest.json**

Add to manifest.json:
```json
"background": {
  "service_worker": "background.js"
}
```

**Step 3: Commit**

```bash
git add extension/background.js extension/manifest.json
git commit -m "feat: background service worker for keyboard shortcut forwarding"
```

---

## Phase 6: Polish & Verification

### Task 15: Codable Migration Safety

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`

**Step 1: Ensure backward compatibility**

The new `webContext` property is optional with a default of `nil`. When decoding existing data that lacks this field, `Codable` will decode it as `nil` automatically (since it's optional). No custom decoder needed.

The new `.webElement` case in `CommentType` is only created by the extension flow, so existing data won't contain it. However, verify that `CommentType`'s Codable synthesis handles the new case correctly.

**Step 2: Test with existing data**

1. Build and relaunch
2. Verify existing comments load correctly in the popover
3. Verify data.json still loads without errors (check `/tmp/remarc_debug.log`)

**Step 3: Commit if any changes needed**

---

### Task 16: End-to-End Testing

**Manual test checklist:**

1. **WebSocket server starts**: Check debug log for "Listening on port 9274"
2. **Extension loads**: Load unpacked extension in Chrome via `chrome://extensions`
3. **Extension connects**: Check Chrome console for "[Remarc] Connected to Remarc", check debug log for "Client connected"
4. **Text selection enrichment**: Select text on a React dev server page, create a Remarc comment, verify webContext is populated in the saved data
5. **Element grab**: Press Cmd+Shift+G, hover to see highlight, click to capture, verify comment created with `.webElement` type
6. **Screenshot enrichment**: Take a screenshot of a browser window, verify webContext attached
7. **Non-React fallback**: Test on a plain HTML page — should get elementHTML but no componentName/filePath
8. **Extension disconnected**: Quit Remarc, verify extension reconnects when Remarc restarts
9. **Existing features**: Verify text selection in non-browser apps still works normally
