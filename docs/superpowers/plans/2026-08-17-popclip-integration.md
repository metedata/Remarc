# PopClip Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a PopClip button open Remarc's comment composer on the current text selection, and make the existing "Hotkey Only" setting actually suppress Remarc's own tooltip so users can run one popup instead of two.

**Architecture:** A module-based PopClip extension calls `remarc://comment`, carrying only an optional browser URL. Remarc receives it through a `kAEGetURL` Apple Event handler and resolves the selection itself from `SelectionMonitor` (live selection, then a short-lived stash of the just-cleared selection, then a fresh clipboard read), then calls the existing `CommentInputController.shared.showForSelection(_:)`. No selection text crosses the URL boundary, so there is nothing for a hostile web page to inject.

**Tech Stack:** Swift 6, SwiftUI + AppKit, swift-testing, PopClip module extension in TypeScript.

**Design spec:** `docs/superpowers/specs/2026-08-17-popclip-integration-design.md`. Read it before starting.

## Global Constraints

- Work in the worktree `.worktrees/popclip-integration` on branch `feat/popclip-integration`. Never on `main`.
- Minimum macOS is 14.0 (`MACOSX_DEPLOYMENT_TARGET` in `app/Config/Shared.xcconfig`). Swift 6.0+.
- Tests use **swift-testing**, not XCTest: `import Testing`, `@Suite`, `@Test`, `#expect`. Match the style of `app/RemarcPackage/Tests/RemarcFeatureTests/CommentWakePolicyTests.swift`.
- Run tests from `app/RemarcPackage`: `swift test --filter <SuiteOrTestName>`.
- **Build and relaunch with `scripts/verify.sh build`**, from the worktree root. It builds Debug, fails loudly on error, and relaunches the app, satisfying the mandatory-relaunch rule in one step. Crucially it also creates `Remarc.xcworkspace`, which is gitignored and therefore **absent in a fresh worktree** — a raw `xcodebuild -workspace` invocation fails here until it exists.
- If you do call `xcodebuild` directly, always `-derivedDataPath "$(pwd)/DerivedData"` with command substitution, never `"$PWD"`, and never pipe it through `tail` or `head` — that masks failures.
- `CHANGELOG.md` groups bullets under version headings that only appear at release time, and it has never carried an `Unreleased` section. Do not invent one. Draft the user-facing bullets in the branch's merge description instead, so the release flow can fold them in. Task 7 has the wording.
- **No em dashes in user-facing text** (UI strings, docs pages). Use hyphens. Code comments and this plan may use them.
- Colors come from `remarc*` tokens in `Views/Colors.swift`, never hardcoded hex.
- Callouts use `CalloutView`, never inline styling. Every new button needs hover and click states.
- PopClip extension identifier is `com.metepolat.remarc.popclip`. Never use a `com.pilotmoon.popclip.extension.*` prefix — that is reserved and gated behind `AllowUnsignedReservedPrefixes`.
- PopClip extension declares `popclipVersion: 4586`.

---

### Task 1: Make Detection mode suppress the tooltip

The `selectionDetectionMode` setting is persisted and displayed but no runtime code reads it, so "Hotkey Only" currently does nothing. This task makes it work by gating the tooltip while leaving `SelectionMonitor` running.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Utilities/SelectionUIPolicy.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/SelectionUIPolicyTests.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipWindowController.swift:36-48`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift:323`

**Interfaces:**
- Consumes: `SettingsManager.SelectionDetectionMode` (existing, `.auto` / `.hotkeyOnly`).
- Produces: `SelectionUIPolicy.shouldShowSelectionUI(isPaused: Bool, mode: SettingsManager.SelectionDetectionMode) -> Bool`. Task 2 does not use it; nothing else depends on it.

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/SelectionUIPolicyTests.swift`:

```swift
import Testing
@testable import RemarcFeature

@Suite("Selection UI policy")
struct SelectionUIPolicyTests {
    @Test("Auto mode shows selection UI when not paused")
    func autoModeShowsUI() {
        #expect(SelectionUIPolicy.shouldShowSelectionUI(isPaused: false, mode: .auto))
    }

    @Test("Hotkey Only hides selection UI")
    func hotkeyOnlyHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: false, mode: .hotkeyOnly))
    }

    @Test("Pausing hides selection UI even in auto mode")
    func pausedHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: true, mode: .auto))
    }

    @Test("Pausing and Hotkey Only together still hide selection UI")
    func pausedHotkeyOnlyHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: true, mode: .hotkeyOnly))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/RemarcPackage && swift test --filter SelectionUIPolicyTests
```

Expected: compile failure, `cannot find 'SelectionUIPolicy' in scope`.

- [ ] **Step 3: Write the policy**

Create `app/RemarcPackage/Sources/RemarcFeature/Utilities/SelectionUIPolicy.swift`:

```swift
/// Whether selection-driven UI (the tooltip) should appear for a detected selection.
///
/// `SelectionMonitor` keeps running in `.hotkeyOnly` because the hotkey's own
/// fresh-read fallback is the weaker path (see `SelectionMonitor.readCurrentSelection`),
/// and because the PopClip URL path depends on the monitor's stashed selection.
/// So the mode is enforced here, at the point of display, not at the monitor.
public enum SelectionUIPolicy {
    public static func shouldShowSelectionUI(
        isPaused: Bool,
        mode: SettingsManager.SelectionDetectionMode
    ) -> Bool {
        !isPaused && mode == .auto
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter SelectionUIPolicyTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Gate the tooltip on the policy**

In `SelectionTooltipWindowController.swift`, replace `setupObservers()` (currently lines 36-48) with:

```swift
    private func setupObservers() {
        SelectionMonitor.shared.$currentSelection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selection in
                guard let self else { return }
                guard let selection else {
                    self.dismiss()
                    return
                }
                guard SelectionUIPolicy.shouldShowSelectionUI(
                    isPaused: SettingsManager.shared.isPaused,
                    mode: SettingsManager.shared.selectionDetectionMode
                ) else {
                    debugLog("Tooltip: suppressed by detection mode")
                    self.dismiss()
                    return
                }
                debugLog("Tooltip: selection received, scheduling show")
                self.scheduleShow(for: selection)
            }
            .store(in: &cancellables)

        // Switching to Hotkey Only while a tooltip is on screen must take effect
        // immediately, not on the next selection.
        SettingsManager.shared.$selectionDetectionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard mode == .hotkeyOnly else { return }
                self?.dismiss()
            }
            .store(in: &cancellables)
    }
```

- [ ] **Step 6: Update the help text to describe what the setting does**

In `PreferencesWindowController.swift`, replace the description at line 323:

```swift
                        Text("Auto-detect shows the Remarc popup as soon as you select text. Hotkey only hides the popup and waits for your shortcut.")
```

- [ ] **Step 7: Build and relaunch**

```bash
scripts/verify.sh build
```

- [ ] **Step 8: Verify by hand**

Open Settings, set Detection mode to Hotkey Only. Select text in any app and confirm no tooltip appears. Press the Remarc hotkey and confirm the composer still opens with the selected text. Switch back to Auto and confirm the tooltip returns. With a tooltip visible, switch to Hotkey Only and confirm it disappears immediately.

- [ ] **Step 9: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/SelectionUIPolicy.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/SelectionUIPolicyTests.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipWindowController.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "fix(settings): make Hotkey Only actually suppress the tooltip

The selectionDetectionMode picker has been writing a UserDefaults key
that no runtime code read, so Hotkey Only did nothing. Gate the tooltip
on it via SelectionUIPolicy and leave SelectionMonitor running: stopping
it would put every hotkey press on the clipboard fallback that
SelectionMonitor documents as less reliable."
```

---

### Task 2: Stash the just-cleared selection

Clicking PopClip's bar is a plain click, and `SelectionMonitor` treats a `clickCount` 1 mouse-up as deselection, clearing `currentSelection` before the URL arrives. This task keeps the cleared selection available for a short window, without changing what the hotkey sees.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Utilities/RecentSelectionStash.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/RecentSelectionStashTests.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SelectionMonitor.swift`

**Interfaces:**
- Consumes: `TextSelection` (existing: `text`, `source`, `appBundleID`, `screenRect`, `timestamp`).
- Produces:
  - `RecentSelectionStash` with `mutating func store(_ selection: TextSelection, at now: CFAbsoluteTime)`, `func selection(at now: CFAbsoluteTime, maxAge: CFAbsoluteTime) -> TextSelection?`, `mutating func clear()`.
  - `SelectionMonitor.readRecentSelection(maxAge: CFAbsoluteTime = 2.0) -> TextSelection?` — Task 4 calls this.

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/RecentSelectionStashTests.swift`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@Suite("Recent selection stash")
struct RecentSelectionStashTests {
    private func makeSelection(_ text: String) -> TextSelection {
        TextSelection(
            text: text,
            source: "Notes",
            appBundleID: "com.apple.Notes",
            screenRect: CGRect(x: 10, y: 20, width: 100, height: 18)
        )
    }

    @Test("A freshly stored selection is returned within the window")
    func freshSelectionIsReturned() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 100.5, maxAge: 2.0)?.text == "hello")
    }

    @Test("A selection older than the window is not returned")
    func staleSelectionIsDropped() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 103.0, maxAge: 2.0) == nil)
    }

    @Test("An empty stash returns nothing")
    func emptyStashReturnsNothing() {
        let stash = RecentSelectionStash()
        #expect(stash.selection(at: 100.0, maxAge: 2.0) == nil)
    }

    @Test("Storing a second selection replaces the first")
    func storeReplaces() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("first"), at: 100.0)
        stash.store(makeSelection("second"), at: 101.0)
        #expect(stash.selection(at: 101.5, maxAge: 2.0)?.text == "second")
    }

    @Test("Clearing discards the stash")
    func clearDiscards() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        stash.clear()
        #expect(stash.selection(at: 100.1, maxAge: 2.0) == nil)
    }

    @Test("The stash preserves the selection rectangle")
    func rectIsPreserved() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 100.1, maxAge: 2.0)?.screenRect?.width == 100)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/RemarcPackage && swift test --filter RecentSelectionStashTests
```

Expected: compile failure, `cannot find 'RecentSelectionStash' in scope`.

- [ ] **Step 3: Write the stash**

Create `app/RemarcPackage/Sources/RemarcFeature/Utilities/RecentSelectionStash.swift`:

```swift
import Foundation

/// Holds the selection `SelectionMonitor` most recently cleared, so a trigger
/// arriving just after a deselecting click can still find it.
///
/// Time is injected rather than read from the clock so the window is testable.
public struct RecentSelectionStash {
    private var selection: TextSelection?
    private var storedAt: CFAbsoluteTime?

    public init() {}

    public mutating func store(_ selection: TextSelection, at now: CFAbsoluteTime) {
        self.selection = selection
        self.storedAt = now
    }

    public func selection(at now: CFAbsoluteTime, maxAge: CFAbsoluteTime) -> TextSelection? {
        guard let selection, let storedAt else { return nil }
        guard now - storedAt <= maxAge else { return nil }
        return selection
    }

    public mutating func clear() {
        selection = nil
        storedAt = nil
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter RecentSelectionStashTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Stash on the deselecting click in SelectionMonitor**

Only the click path, not every clear. A click on another app's UI is what PopClip's bar produces, and it is the only clear this feature needs. Stashing on keystroke dismissal or on a failed text read would widen the window for resurrecting a selection the user did not mean to reuse, for no benefit.

In `SelectionMonitor.swift`, add the property next to the other private state (after `private var gestureStartPasteboardChangeCount: Int?`):

```swift
    /// The last selection cleared, kept briefly for triggers that arrive after a
    /// deselecting click. Read only via `readRecentSelection`; the hotkey path
    /// deliberately does not consult it.
    private var recentStash = RecentSelectionStash()
```

Then, in `handleMouseEvent`, in the `.leftMouseUp` branch, replace:

```swift
            } else if event.clickCount < 2 && currentSelection != nil {
                // Simple click (not double-click, not drag) = deselection
                // Only clear if we had a selection — don't AX query on every click
                currentSelection = nil
                lastReadText = ""
            }
```

with:

```swift
            } else if event.clickCount < 2, let dismissed = currentSelection {
                // Simple click (not double-click, not drag) = deselection.
                // Stash it: a click on PopClip's bar lands here, and the
                // remarc:// trigger that follows still needs the selection.
                recentStash.store(dismissed, at: CFAbsoluteTimeGetCurrent())
                currentSelection = nil
                lastReadText = ""
            }
```

Leave the `keyMonitor` clear and the `performTextRead` clear exactly as they are.

- [ ] **Step 6: Add the read accessor**

In `SelectionMonitor.swift`, add after `readCurrentSelection()`:

```swift
    /// Selection resolution for external triggers (currently the `remarc://` URL
    /// handler). Unlike `readCurrentSelection`, this consults the stash, because
    /// the click that invoked the trigger has already cleared the live selection.
    ///
    /// The stash is consumed on read. Leaving it in place would let a second
    /// trigger inside the window silently reuse a selection the user has already
    /// moved on from, producing a duplicate comment on stale text.
    public func readRecentSelection(maxAge: CFAbsoluteTime = 2.0) -> TextSelection? {
        if let existing = currentSelection {
            debugLog("readRecentSelection: using live selection")
            return existing
        }
        if let stashed = recentStash.selection(at: CFAbsoluteTimeGetCurrent(), maxAge: maxAge) {
            recentStash.clear()
            debugLog("readRecentSelection: using stashed selection")
            return stashed
        }
        debugLog("readRecentSelection: falling back to a fresh read")
        return readCurrentSelection()
    }
```

Also clear the stash in `stopMonitoring()`, next to the existing resets:

```swift
        recentStash.clear()
```

- [ ] **Step 7: Run the full test suite**

```bash
cd app/RemarcPackage && swift test
```

Expected: all tests pass. Nothing existing depends on the cleared-selection behaviour, so there should be no regressions.

- [ ] **Step 8: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/RecentSelectionStash.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/RecentSelectionStashTests.swift \
        app/RemarcPackage/Sources/RemarcFeature/Services/SelectionMonitor.swift
git commit -m "feat(selection): keep the just-cleared selection briefly

A click on another app's UI clears currentSelection, which is exactly
what happens when the user clicks PopClip's bar. Stash the cleared
selection for 2s and expose readRecentSelection for external triggers.
The hotkey path still uses readCurrentSelection and cannot resurrect a
selection the user deliberately dismissed."
```

---

### Task 3: Parse the remarc:// URL

Pure parsing, no AppKit, no side effects. Follows the project's existing policy-type idiom (`CommentWakePolicy`, `ScreenshotWebContextPolicy`).

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Utilities/RemarcURLRequest.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/RemarcURLRequestTests.swift`

**Interfaces:**
- Produces: `RemarcURLRequest` with `let pageUrl: String?` and `static func parse(_ url: URL) -> RemarcURLRequest?`. Task 4 calls `parse`.

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/RemarcURLRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@Suite("Remarc URL request")
struct RemarcURLRequestTests {
    @Test("A bare comment URL parses with no context")
    func bareCommentURL() {
        let request = RemarcURLRequest.parse(URL(string: "remarc://comment")!)
        #expect(request != nil)
        #expect(request?.pageUrl == nil)
        #expect(request?.pageTitle == nil)
    }

    @Test("Browser url and title are captured")
    func browserContextCaptured() {
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa&title=Example%20Page")!
        let request = RemarcURLRequest.parse(url)
        #expect(request?.pageUrl == "https://example.com/a")
        #expect(request?.pageTitle == "Example Page")
    }

    /// The extension builds its query with URLSearchParams, which serializes as
    /// application/x-www-form-urlencoded and therefore encodes a space as "+".
    /// URLComponents.queryItems percent-decodes but leaves "+" alone, so without
    /// explicit handling every multi-word title arrives with plus signs in it.
    /// This is the exact string the shipped extension emits - do not "simplify"
    /// it to %20, which is what hid this bug in the first draft.
    @Test("Plus-encoded spaces from URLSearchParams decode to spaces")
    func plusEncodedSpacesDecode() {
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa&title=Example+Page+Two")!
        #expect(RemarcURLRequest.parse(url)?.pageTitle == "Example Page Two")
    }

    @Test("A literal plus in a page url survives decoding")
    func literalPlusInURLSurvives() {
        // %2B is how a real "+" in a URL is encoded, and it must not become a space.
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa%2Bb")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == "https://example.com/a+b")
    }

    @Test("An unknown host is rejected")
    func unknownHostRejected() {
        #expect(RemarcURLRequest.parse(URL(string: "remarc://export?url=x")!) == nil)
    }

    @Test("A foreign scheme is rejected")
    func foreignSchemeRejected() {
        #expect(RemarcURLRequest.parse(URL(string: "https://comment")!) == nil)
    }

    @Test("An oversized page url is dropped rather than stored")
    func oversizedPageURLDropped() {
        let long = String(repeating: "a", count: 3000)
        let url = URL(string: "remarc://comment?url=https://example.com/\(long)")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }

    @Test("An oversized title is dropped rather than stored")
    func oversizedTitleDropped() {
        let long = String(repeating: "b", count: 1000)
        let url = URL(string: "remarc://comment?title=\(long)")!
        #expect(RemarcURLRequest.parse(url)?.pageTitle == nil)
    }

    @Test("Empty parameter values are treated as absent")
    func emptyValuesAreAbsent() {
        let request = RemarcURLRequest.parse(URL(string: "remarc://comment?url=&title=")!)
        #expect(request?.pageUrl == nil)
        #expect(request?.pageTitle == nil)
    }

    @Test("A non-http page url is rejected")
    func nonHTTPPageURLRejected() {
        let url = URL(string: "remarc://comment?url=javascript%3Aalert(1)")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/RemarcPackage && swift test --filter RemarcURLRequestTests
```

Expected: compile failure, `cannot find 'RemarcURLRequest' in scope`.

- [ ] **Step 3: Write the parser**

Create `app/RemarcPackage/Sources/RemarcFeature/Utilities/RemarcURLRequest.swift`:

```swift
import Foundation

/// A parsed `remarc://comment` request.
///
/// The URL deliberately carries no selection text: Remarc re-reads its own
/// selection, so a hostile page cannot inject content into a comment. The one
/// context value it does carry is page metadata Remarc cannot see for itself,
/// and it is untrusted - a page can put anything here.
public struct RemarcURLRequest: Equatable, Sendable {
    public static let scheme = "remarc"
    public static let commentHost = "comment"
    static let maxPageURLLength = 2048

    public let pageUrl: String?

    public static func parse(_ url: URL) -> RemarcURLRequest? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host?.lowercased() == commentHost else { return nil }

        // Read the raw query and decode it ourselves. The extension builds its
        // query with URLSearchParams, which serializes as
        // application/x-www-form-urlencoded and encodes a space as "+".
        // URLComponents.queryItems percent-decodes but leaves "+" untouched, so
        // relying on it turns every multi-word value into "Example+Page".
        let rawItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQueryItems ?? []
        func value(_ name: String) -> String? {
            guard let encoded = rawItems.first(where: { $0.name == name })?.value else { return nil }
            let spaced = encoded.replacingOccurrences(of: "+", with: "%20")
            guard let decoded = spaced.removingPercentEncoding, !decoded.isEmpty else { return nil }
            return decoded
        }

        var pageUrl = value("url")
        if let candidate = pageUrl {
            let scheme = URL(string: candidate)?.scheme?.lowercased()
            let isWebPage = scheme == "http" || scheme == "https"
            if !isWebPage || candidate.count > maxPageURLLength {
                pageUrl = nil
            }
        }

        return RemarcURLRequest(pageUrl: pageUrl)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter RemarcURLRequestTests
```

Expected: 10 tests pass. If `plusEncodedSpacesDecode` fails, the parser is still relying on `queryItems` and every multi-word page title will ship with plus signs in it.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/RemarcURLRequest.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/RemarcURLRequestTests.swift
git commit -m "feat(url): parse remarc://comment requests

Carries no selection text by design, so there is nothing for a web page
to inject. The two page-metadata values it does accept are capped and
restricted to http(s)."
```

---

### Task 4: Receive the URL and open the composer

Registers the Apple Event handler, queues URLs that arrive before the app finishes setting up, and calls the existing composer entry point.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Utilities/PendingURLQueue.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/PendingURLQueueTests.swift`
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/RemarcURLHandler.swift`
- Modify: `app/Remarc/Info.plist`
- Modify: `app/Remarc/RemarcApp.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift:59-80`

**Interfaces:**
- Consumes: `RemarcURLRequest.parse(_:)` (Task 3), `SelectionMonitor.readRecentSelection(maxAge:)` (Task 2), existing `CommentInputController.shared.showForSelection(_:)`, existing `WebContext(pageUrl:)`.
- Produces:
  - `PendingURLQueue` with `mutating func enqueue(_ url: URL)`, `mutating func markReady() -> [URL]`, `mutating func discardAll()`, `var isReady: Bool`.
  - `RemarcURLHandler.shared.register()` and `RemarcURLHandler.shared.markReady()` — called from `RemarcApp.swift` and `AppController` respectively.

- [ ] **Step 1: Write the failing queue test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/PendingURLQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@Suite("Pending URL queue")
struct PendingURLQueueTests {
    private let a = URL(string: "remarc://comment?title=A")!
    private let b = URL(string: "remarc://comment?title=B")!

    @Test("URLs enqueued before ready are released in order on markReady")
    func queuedUntilReady() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        queue.enqueue(b)
        #expect(queue.markReady() == [a, b])
    }

    @Test("markReady returns nothing the second time")
    func markReadyDrains() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        _ = queue.markReady()
        #expect(queue.markReady().isEmpty)
    }

    @Test("Once ready, the queue reports ready so callers handle URLs directly")
    func readyFlagFlips() {
        var queue = PendingURLQueue()
        #expect(!queue.isReady)
        _ = queue.markReady()
        #expect(queue.isReady)
    }

    @Test("discardAll drops queued URLs and leaves the queue not ready")
    func discardDrops() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        queue.discardAll()
        #expect(queue.markReady().isEmpty)
    }

    @Test("The queue is bounded so a flood cannot grow without limit")
    func queueIsBounded() {
        var queue = PendingURLQueue()
        for _ in 0..<50 { queue.enqueue(a) }
        #expect(queue.markReady().count <= PendingURLQueue.maxQueued)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/RemarcPackage && swift test --filter PendingURLQueueTests
```

Expected: compile failure, `cannot find 'PendingURLQueue' in scope`.

- [ ] **Step 3: Write the queue**

Create `app/RemarcPackage/Sources/RemarcFeature/Utilities/PendingURLQueue.swift`:

```swift
import Foundation

/// Holds `remarc://` URLs that arrive before the app has finished launching.
///
/// `applicationWillFinishLaunching` can defer setup entirely, or terminate the
/// process when a duplicate copy is already running, so a URL can land before
/// there is anything to handle it.
public struct PendingURLQueue {
    public static let maxQueued = 8

    private var queued: [URL] = []
    public private(set) var isReady = false

    public init() {}

    public mutating func enqueue(_ url: URL) {
        guard queued.count < Self.maxQueued else { return }
        queued.append(url)
    }

    public mutating func markReady() -> [URL] {
        isReady = true
        let released = queued
        queued.removeAll()
        return released
    }

    public mutating func discardAll() {
        queued.removeAll()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter PendingURLQueueTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Add the two WebSocketService members the handler will need**

Do this before writing the handler, or the handler will not compile.

In `WebSocketService.swift`, add next to the other pending-context accessors (after `clearPendingRegionElements()`):

```swift
    /// True when no live web context from the Chrome extension is held. Used by
    /// the `remarc://` path to decide whether its own page metadata is needed.
    public var pendingWebContextIsAbsent: Bool {
        pendingWebContext == nil
    }

    /// Adopt page context supplied by something other than the Chrome extension
    /// (currently the PopClip URL path). Never overwrites live extension context.
    public func adoptExternalPageContext(_ context: WebContext) {
        guard pendingWebContext == nil else { return }
        pendingWebContext = context
        pendingWebContextReceivedAt = Date()
    }
```

- [ ] **Step 6: Write the handler**

Create `app/RemarcPackage/Sources/RemarcFeature/Services/RemarcURLHandler.swift`.

Two details that will otherwise cost you a confusing compile error. The class **must** inherit from `NSObject`: `setEventHandler(_:andSelector:...)` is target-action, and a plain Swift class cannot expose an `@objc` method. And the `@objc` entry point is `nonisolated`, extracting the string before hopping to the main actor with a `Task`, because an `@objc` selector on an actor-isolated method fights Swift 6 strict concurrency. Do not "optimise" that `Task` into `MainActor.assumeIsolated`: Apple Events are believed to arrive on the main thread, but `assumeIsolated` traps if that is ever untrue, and trapping on input from another process is a bad trade for saving one run-loop turn.

```swift
import AppKit

/// Handles incoming `remarc://` URLs.
///
/// Registered as a `kAEGetURL` Apple Event handler rather than through
/// `application(_:open:)`: this app's only SwiftUI scene is `Settings`, and the
/// delegate method is unreliable under the SwiftUI lifecycle for scene shapes
/// other than `WindowGroup`.
@MainActor
public final class RemarcURLHandler: NSObject {
    public static let shared = RemarcURLHandler()

    private var queue = PendingURLQueue()

    private override init() {
        super.init()
    }

    /// Call from `applicationWillFinishLaunching`, before any URL can arrive.
    public func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        debugLog("RemarcURLHandler: registered for kAEGetURL")
    }

    /// Call once app setup is complete, to release anything queued during launch.
    ///
    /// If the user never finishes onboarding, `completeSetup` never runs and this
    /// is never called, so URLs stay queued until the queue's cap and are then
    /// dropped. That is the correct outcome: there is no session to file a
    /// comment into before setup completes.
    public func markReady() {
        let released = queue.markReady()
        debugLog("RemarcURLHandler: ready, releasing \(released.count) queued URL(s)")
        for url in released {
            handle(url)
        }
    }

    /// Call when this process is terminating as a duplicate copy, so a URL that
    /// arrived here is not acted on by a process that is about to exit.
    public func discardQueued() {
        queue.discardAll()
    }

    @objc private nonisolated func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent: NSAppleEventDescriptor
    ) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else {
            debugLog("RemarcURLHandler: event carried no usable URL")
            return
        }
        // Task rather than MainActor.assumeIsolated: Apple Events are believed to
        // arrive on the main thread, but assumeIsolated traps if that is ever
        // untrue, and trapping on input from another process is a bad trade for
        // saving one run-loop turn.
        Task { @MainActor in
            RemarcURLHandler.shared.receive(url)
        }
    }

    private func receive(_ url: URL) {
        // Which bundle received this matters: several Remarc copies can be
        // installed (worktree Debug builds, an AppMover source copy), and
        // LaunchServices picks one. Log it so a misroute is visible.
        debugLog("RemarcURLHandler: received \(url.absoluteString) in \(Bundle.main.bundleURL.path)")

        guard queue.isReady else {
            debugLog("RemarcURLHandler: not ready, queueing")
            queue.enqueue(url)
            return
        }
        handle(url)
    }

    private func handle(_ url: URL) {
        guard let request = RemarcURLRequest.parse(url) else {
            debugLog("RemarcURLHandler: ignoring unrecognised URL")
            return
        }
        guard !SettingsManager.shared.isPaused else {
            debugLog("RemarcURLHandler: paused, dropping URL")
            return
        }
        guard let selection = SelectionMonitor.shared.readRecentSelection() else {
            // No feedback surface exists outside the popover, so this is silent
            // to the user. Tracked in the design spec as a known gap.
            debugLog("RemarcURLHandler: no selection could be resolved, dropping URL")
            return
        }

        // PopClip's page metadata is only a fallback for browsers without the
        // Chrome extension. When the extension has live context, leave it alone.
        if let pageUrl = request.pageUrl,
           WebSocketService.shared.pendingWebContextIsAbsent {
            WebSocketService.shared.adoptExternalPageContext(
                WebContext(pageUrl: pageUrl)
            )
        }

        debugLog("RemarcURLHandler: opening composer for \"\(selection.text.prefix(40))\"")
        CommentInputController.shared.showForSelection(selection)
    }
}
```

- [ ] **Step 7: Register the URL scheme in Info.plist**

In `app/Remarc/Info.plist`, add inside the top-level `<dict>`:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.metepolat.Remarc</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>remarc</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 8: Wire the handler into the app lifecycle**

In `app/Remarc/RemarcApp.swift`, at the end of `applicationWillFinishLaunching`, after the existing `#if !DEBUG` block:

```swift
        RemarcURLHandler.shared.register()
        if shouldSkipSetup {
            // This process is handing off to the installed copy or exiting.
            RemarcURLHandler.shared.discardQueued()
        }
```

In `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`, at the end of `completeSetup(withHotkey:)`, after `GlobalHotkey.shared.register()`:

```swift
        RemarcURLHandler.shared.markReady()
        debugLog("RemarcURLHandler ready")
```

- [ ] **Step 9: Run the full test suite**

```bash
cd app/RemarcPackage && swift test
```

Expected: all tests pass.

- [ ] **Step 10: Build and relaunch**

```bash
scripts/verify.sh build
```

- [ ] **Step 11: Verify the Apple Event actually fires**

This is the riskiest assumption in the plan, so prove it before Task 5 depends on it. Select text in Notes, then run:

```bash
open "remarc://comment?url=https://example.com/&title=Example"
```

Expected: the composer opens containing the selected text. Then confirm the handler ran and reached the right bundle:

```bash
grep "RemarcURLHandler" /tmp/remarc_debug.log | tail -5
```

The logged bundle path must be `app/DerivedData/Build/Products/Debug/Remarc.app`. If it names a different copy, LaunchServices routed the URL elsewhere — quit the other copies and retry before continuing.

If no handler line appears at all, the Apple Event registration is not working. Do not paper over it by adding `application(_:open:)` as well; diagnose first, because the spec's transport choice rests on this.

- [ ] **Step 12: Verify the paused and no-selection paths**

With Remarc paused from the menu bar, run the same `open` command and confirm nothing happens and the log shows `paused, dropping URL`. Then unpause, click somewhere to leave no selection, wait 3 seconds, and confirm the log shows `no selection could be resolved`.

- [ ] **Step 13: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/PendingURLQueue.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/PendingURLQueueTests.swift \
        app/RemarcPackage/Sources/RemarcFeature/Services/RemarcURLHandler.swift \
        app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift \
        app/RemarcPackage/Sources/RemarcFeature/AppController.swift \
        app/Remarc/Info.plist app/Remarc/RemarcApp.swift
git commit -m "feat(url): handle remarc://comment via kAEGetURL

Resolves the selection from SelectionMonitor rather than the URL, so
nothing external supplies comment text. Queues URLs that arrive during
launch, drops them in a process that is exiting as a duplicate copy, and
logs the receiving bundle path so a misroute to another installed Remarc
is visible instead of looking like an inert button."
```

---

### Task 5: Build the PopClip extension package

**Files:**
- Create: `popclip/Remarc.popclipext/Config.ts`
- Create: `popclip/Remarc.popclipext/remarc-logo.svg` (copy of `assets/remarc-logo.svg`)
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/PopClipExtensionPackageTests.swift`
- Modify: `app/Remarc.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the `remarc://comment` contract from Task 3.
- Produces: `Remarc.popclipext` inside the built app at `Contents/Resources/Remarc.popclipext`. Task 6 opens it.

- [ ] **Step 1: Write the extension config**

Create `popclip/Remarc.popclipext/Config.ts`:

```ts
// #popclip
// name: Remarc
// identifier: com.metepolat.remarc.popclip
// description: Comment on the selected text in Remarc.
// popclipVersion: 4586
// icon: remarc-logo.svg
// app: { name: Remarc, link: https://remarc.app, bundleIdentifier: com.metepolat.Remarc, checkInstalled: true }

// Deliberately sends no selection text. Remarc re-reads its own selection, which
// keeps the comment text identical to the hotkey path, preserves the selection
// rectangle so the composer anchors correctly, and leaves a hostile page with
// nothing to inject. The only value passed is the page URL, which Remarc cannot
// see for itself in browsers without the Chrome extension. Do not add a title:
// Remarc has no field for it and stopped parsing it in Task 4.
export const action: Action = {
	code(_input, _options, context) {
		const url = new URL("remarc://comment");
		if (context.browserUrl) {
			url.searchParams.set("url", context.browserUrl);
		}
		// activate:false keeps focus in the source app, matching how Remarc's own
		// hotkey behaves; its composer is a non-activating panel.
		popclip.openUrl(url.href, { activate: false });
	},
};
```

- [ ] **Step 2: Add the icon**

```bash
cp assets/remarc-logo.svg popclip/Remarc.popclipext/remarc-logo.svg
```

- [ ] **Step 3: Write the failing package test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/PopClipExtensionPackageTests.swift`. This asserts against the repo file, following the pattern used by `OpenSourceReadinessTests`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@Suite("PopClip extension package")
struct PopClipExtensionPackageTests {
    /// Walks up from this test file to the repo root, so the suite does not
    /// depend on the working directory the test runner happens to use.
    private static func repoRoot(from file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) {
                return url
            }
        }
        fatalError("Could not locate repo root from \(file)")
    }

    private static var config: String {
        let path = repoRoot()
            .appendingPathComponent("popclip/Remarc.popclipext/Config.ts")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    @Test("Config declares the Remarc identifier")
    func declaresIdentifier() {
        #expect(Self.config.contains("identifier: com.metepolat.remarc.popclip"))
    }

    @Test("Config does not claim a reserved Pilotmoon identifier prefix")
    func avoidsReservedPrefix() {
        #expect(!Self.config.contains("com.pilotmoon.popclip.extension"))
    }

    @Test("Config declares a popclipVersion new enough for module extensions")
    func declaresModuleCapableVersion() {
        #expect(Self.config.contains("popclipVersion: 4586"))
    }

    /// Checks the declaration, not the word. A substring search for "entitlements"
    /// would fail on a code comment that merely mentions them.
    @Test("Config declares no entitlements, which is what avoids the unsigned warning")
    func declaresNoEntitlements() {
        let declarations = Self.config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("entitlements") || $0.hasPrefix("// entitlements") }
        #expect(declarations.isEmpty)
    }

    @Test("The action targets the remarc://comment host")
    func targetsCommentHost() {
        #expect(Self.config.contains("remarc://comment"))
    }

    @Test("The action never sends selection text")
    func sendsNoSelectionText() {
        #expect(!Self.config.contains("input.text"))
        #expect(!Self.config.contains("input.markdown"))
    }

    @Test("The icon referenced by the config exists in the package")
    func iconExists() {
        let icon = Self.repoRoot()
            .appendingPathComponent("popclip/Remarc.popclipext/remarc-logo.svg")
        #expect(FileManager.default.fileExists(atPath: icon.path))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter PopClipExtensionPackageTests
```

Expected: 7 tests pass. If `declaresNoEntitlements` fails, the config gained an entitlement and the no-warning property is lost — remove it rather than relaxing the test.

- [ ] **Step 5: Copy the package into the app bundle at build time**

The Xcode project uses synchronized folder groups, so a `.popclipext` directory dropped into `app/Remarc/` would be recursed into and flattened rather than copied as a package. Use a shell script phase instead, mirroring the existing "Copy MCP Server" phase.

In `app/Remarc.xcodeproj/project.pbxproj`, inside the `PBXShellScriptBuildPhase` section and immediately after the closing `};` of the `Copy MCP Server` phase, add:

```
		A1PCL0012DEDD000000000001 /* Copy PopClip Extension */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(SRCROOT)/../popclip/Remarc.popclipext/Config.ts",
				"$(SRCROOT)/../popclip/Remarc.popclipext/remarc-logo.svg",
			);
			name = "Copy PopClip Extension";
			outputPaths = (
				"$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Remarc.popclipext/Config.ts",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "# Ship the PopClip extension as a package directory, not loose files.\nset -euo pipefail\n\nSRC=\"${SRCROOT}/../popclip/Remarc.popclipext\"\ntest -s \"$SRC/Config.ts\"\ntest -s \"$SRC/remarc-logo.svg\"\n\nRES=\"${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}\"\n# This phase is the only destructive step in the build. Confirm the target is a\n# real directory before rm -rf touches anything: set -u catches an unset\n# variable but not an empty one, and an empty RES would aim rm at \"/\".\nif [ ! -d \"$RES\" ]; then\n  echo \"error: resources directory not found at '$RES'\" >&2\n  exit 1\nfi\nrm -rf \"$RES/Remarc.popclipext\"\ncp -R \"$SRC\" \"$RES/Remarc.popclipext\"\n";
		};
```

Then add it to the target's `buildPhases` list, after the `Copy MCP Server` entry:

```
				A1PCL0012DEDD000000000001 /* Copy PopClip Extension */,
```

- [ ] **Step 6: Build and verify the package shipped intact**

```bash
scripts/verify.sh build
```

```bash
ls -R app/DerivedData/Build/Products/Debug/Remarc.app/Contents/Resources/Remarc.popclipext
```

Expected: a directory containing `Config.ts` and `remarc-logo.svg`. If the files landed loose in `Resources/` instead, the build phase did not run — check it appears in the target's `buildPhases`.

- [ ] **Step 7: Relaunch**

```bash
scripts/verify.sh launch
```

- [ ] **Step 8: Install the extension by hand and verify the round trip**

```bash
open app/DerivedData/Build/Products/Debug/Remarc.app/Contents/Resources/Remarc.popclipext
```

PopClip should offer to install it, with **no unsigned-extension warning**. If a warning appears, the config gained a shell script, AppleScript, or an entitlement.

Then work through all five cases:

1. **Notes.** Select text, click Remarc in the PopClip bar. The composer opens with the selected text, anchored to the selection rather than floating at the cursor, and focus stays with Notes.
2. **Save and dismiss.** Save a comment, then confirm the caret is still live in Notes and typing goes there. Repeat with Escape instead of save. This is what `activate: false` is for; if focus does not return, the spec's assumption about it is wrong and needs resolving before Task 6.
3. **Safari.** Confirm the page URL is attached to the comment.
4. **Chrome with the Remarc extension installed and connected.** Confirm the extension's region context still attaches and PopClip's `url` has not replaced it. This is what `adoptExternalPageContext`'s guard protects.
5. **Remarc not running.** Quit Remarc, select text, click the PopClip button. Expected: Remarc launches and the clipboard fallback still produces a comment. If it opens an empty composer or nothing at all, note it and check the log rather than assuming the queue is broken.

- [ ] **Step 9: Commit**

```bash
git add popclip/ app/RemarcPackage/Tests/RemarcFeatureTests/PopClipExtensionPackageTests.swift \
        app/Remarc.xcodeproj/project.pbxproj
git commit -m "feat(popclip): add the Remarc PopClip extension

Module-based Config.ts following the shape Craft and UpNote use, sending
only page metadata. Shipped as a package directory via a shell script
build phase, mirroring Copy MCP Server: the project uses synchronized
folder groups, which would recurse into a .popclipext directory and
flatten it."
```

---

### Task 6: Install affordance in Preferences

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/PopClipInstaller.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/PopClipInstallerTests.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift:321-327`

**Interfaces:**
- Consumes: the bundled package from Task 5.
- Produces: `PopClipInstaller.isInstalled(lookup:)`, `PopClipInstaller.bundledPackageURL(in:)`, `PopClipInstaller.shared.install()`.

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/PopClipInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import RemarcFeature

@Suite("PopClip installer")
struct PopClipInstallerTests {
    @Test("PopClip counts as installed when the bundle identifier resolves")
    func installedWhenResolved() {
        #expect(PopClipInstaller.isInstalled { _ in URL(fileURLWithPath: "/Applications/PopClip.app") })
    }

    @Test("PopClip counts as absent when the bundle identifier does not resolve")
    func absentWhenUnresolved() {
        #expect(!PopClipInstaller.isInstalled { _ in nil })
    }

    @Test("Only PopClip's bundle identifier is queried")
    func queriesPopClipIdentifier() {
        var queried: [String] = []
        _ = PopClipInstaller.isInstalled { identifier in
            queried.append(identifier)
            return nil
        }
        #expect(queried == ["com.pilotmoon.popclip"])
    }

    @Test("The bundled package path sits in the app's Resources")
    func bundledPackagePath() {
        let base = URL(fileURLWithPath: "/tmp/Remarc.app/Contents/Resources")
        let package = PopClipInstaller.bundledPackageURL(in: base)
        #expect(package.lastPathComponent == "Remarc.popclipext")
        #expect(package.deletingLastPathComponent() == base)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/RemarcPackage && swift test --filter PopClipInstallerTests
```

Expected: compile failure, `cannot find 'PopClipInstaller' in scope`.

- [ ] **Step 3: Write the installer**

Create `app/RemarcPackage/Sources/RemarcFeature/Services/PopClipInstaller.swift`:

```swift
import AppKit

/// Detects PopClip and hands it the bundled extension package.
///
/// Detection is a synchronous LaunchServices lookup, not a CLI spawn, so none of
/// the `ProcessRunner` rules that govern the Claude Code and Codex plugin
/// detectors apply here.
@MainActor
public final class PopClipInstaller {
    public static let shared = PopClipInstaller()
    public static let popClipBundleIdentifier = "com.pilotmoon.popclip"
    public static let packageName = "Remarc.popclipext"

    private init() {}

    public static func isInstalled(
        lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> Bool {
        lookup(popClipBundleIdentifier) != nil
    }

    public static func bundledPackageURL(in resourcesDirectory: URL) -> URL {
        resourcesDirectory.appendingPathComponent(packageName)
    }

    /// Opens the bundled package so PopClip shows its own install dialog.
    /// Returns false when the package is missing from this build.
    @discardableResult
    public func install() -> Bool {
        guard let resources = Bundle.main.resourceURL else {
            debugLog("PopClipInstaller: no resource URL")
            return false
        }
        let package = Self.bundledPackageURL(in: resources)
        guard FileManager.default.fileExists(atPath: package.path) else {
            debugLog("PopClipInstaller: bundled package missing at \(package.path)")
            return false
        }
        debugLog("PopClipInstaller: opening \(package.path)")
        return NSWorkspace.shared.open(package)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app/RemarcPackage && swift test --filter PopClipInstallerTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Add the callout and button to Preferences**

In `PreferencesWindowController.swift`, replace the Detection mode block (lines 321-327 after Task 1's edit) with:

```swift
                    VStack(alignment: .leading, spacing: 3) {
                        pickerRow("Detection mode", selection: $settings.selectionDetectionMode) { $0.label }
                        Text("Auto-detect shows the Remarc popup as soon as you select text. Hotkey only hides the popup and waits for your shortcut.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                        if PopClipInstaller.isInstalled() {
                            CalloutView(.info, "Using PopClip? Set this to Hotkey Only and add the Remarc PopClip extension so only one popup appears on selection.") {
                                GetExtensionButton(
                                    title: "Install PopClip Extension",
                                    help: "Install the Remarc PopClip extension"
                                ) {
                                    PopClipInstaller.shared.install()
                                }
                            }
                        }
                    }
```

Reuse `GetExtensionButton`, the private capsule button already used for the Chrome extension at `PreferencesWindowController.swift:1440`. It is the closest existing precedent (a Preferences CTA that installs a companion integration) and already has a hover state. It is currently hardcoded, so parameterise it with defaults that leave the existing call site untouched. At `PreferencesWindowController.swift:2726-2727`, replace:

```swift
private struct GetExtensionButton: View {
    var action: () -> Void
```

with:

```swift
private struct GetExtensionButton: View {
    var title: String = "Get Extension"
    var help: String = "Get Chrome extension"
    var action: () -> Void
```

Then replace the hardcoded `Text("Get Extension")` at line 2736 with `Text(title)`, and the hardcoded `.help("Get Chrome extension")` at line 2755 with `.help(help)`.

`GetExtensionButton` currently has a hover state but no pressed state, which does not meet the global constraint that every button carries both. Add one to the shared component rather than working around it, so the Chrome extension's button gets the same treatment. Give it a pressed flag driven by the button's own gesture state and fold it into the existing opacity ramps:

```swift
    @State private var isHovered = false
    @State private var isPressed = false
```

Apply it alongside `isHovered` in the three places that already branch on hover, deepening each by roughly the same step hover uses, so pressing reads as one notch beyond hover rather than a new visual language:

```swift
            .foregroundStyle(.primary.opacity(isPressed ? 0.85 : (isHovered ? 0.7 : 0.55)))
```

```swift
                Capsule()
                    .fill(Color.primary.opacity(isPressed ? 0.16 : (isHovered ? 0.1 : 0.06)))
```

```swift
                Capsule()
                    .strokeBorder(Color.primary.opacity(isPressed ? 0.22 : (isHovered ? 0.16 : 0.1)), lineWidth: 0.5)
```

Drive `isPressed` with a simultaneous gesture so the button's action still fires normally:

```swift
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
```

Because this touches shared UI, check the Chrome extension's own "Get Extension" button in Preferences afterwards as well as the new one.

Do **not** use `ExpandingCTAButton` here. It collapses to a bare symbol until hover, and its own documentation says it is for "secondary actions that should stay quiet until the pointer is nearby." An install button inside a callout the user is reading is not that.

- [ ] **Step 6: Build and relaunch**

```bash
scripts/verify.sh build
```

- [ ] **Step 7: Verify the affordance**

Open Settings. With PopClip installed, the callout and button appear under Detection mode. Click Install and confirm PopClip's install dialog appears with no unsigned warning. **Click Install a second time** and record what PopClip does: updates in place, duplicates, or refuses. If it duplicates, note it in the docs page in Task 7 rather than adding detection logic.

Check the button's hover and click states, and check the callout in both light and dark appearance.

- [ ] **Step 8: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/PopClipInstaller.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/PopClipInstallerTests.swift \
        app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat(settings): offer the PopClip extension under Detection mode

Shown only when PopClip is installed, detected with a synchronous
LaunchServices lookup. Install opens the bundled package so PopClip runs
its own install dialog."
```

---

### Task 7: Document it

**Files:**
- Create: `docs-site/src/content/docs/basics/popclip.md`
- Modify: `docs-site/astro.config.mjs` (the `sidebar` array, starting line 41)

**Interfaces:** none.

- [ ] **Step 1: Read the neighbouring docs page**

```bash
cat docs-site/src/content/docs/basics/commenting-on-selections.md
```

That is the sibling this page sits next to. Copy its frontmatter shape, heading levels, and voice exactly. Do not invent a new structure. Also read `docs-site/src/content/docs/chrome-extension.md`, which is the closest analogue: a companion integration with an install flow and a troubleshooting list.

- [ ] **Step 2: Write the page**

Cover, in this order, using hyphens and never em dashes:

1. What the extension does: adds a Remarc button to the PopClip bar that opens the comment composer on your selection.
2. Installing it: Settings, App, Install PopClip Extension. Note that the button only appears when PopClip is installed.
3. Turning off the second popup: set Detection mode to Hotkey Only, so PopClip's bar is the only thing that appears.
4. Troubleshooting, one short list:
   - Nothing happens when you click the Remarc button: Remarc may not be running. Start it and select the text again.
   - Nothing happens and Remarc is running: Remarc may be paused. Check the menu bar.
   - The page URL is missing on comments from Arc: Arc does not report page URLs to PopClip.
   - Whatever Step 7 of Task 6 revealed about pressing Install twice.

- [ ] **Step 3: Add the page to the sidebar**

The sidebar is hand-written, not autogenerated, so a new page is invisible until listed. In `docs-site/astro.config.mjs`, add to the `Basics` group's `items` array, after the `basics/commenting-on-selections` entry:

```js
						{ label: 'PopClip', slug: 'basics/popclip' },
```

- [ ] **Step 4: Build the docs site to confirm the page compiles**

```bash
cd docs-site && npm run build
```

Expected: build succeeds and the new page is listed in the output.

- [ ] **Step 5: Commit**

```bash
git add docs-site/
git commit -m "docs: add the PopClip extension page"
```

---

---

### Task 8: Draft the release bullets

`CHANGELOG.md` bullets are user-facing, high level, and grouped under a version heading written at release time. Two bullets cover this branch. Put them in the branch's merge description so the release flow can pick them up; do not add a version heading yourself.

- [ ] **Step 1: Write the bullets**

Use hyphens, never em dashes, and keep them at the altitude of the existing entries:

```markdown
- Detection mode "Hotkey Only" now really does hide the selection popup, so the hotkey can be the only way Remarc appears
- New PopClip extension: add a Remarc button to the PopClip bar and comment on a selection from there (install it from Preferences)
```

- [ ] **Step 2: Check them against the file**

```bash
sed -n '1,20p' CHANGELOG.md
```

Confirm the tone matches. If either bullet reads like a commit message rather than something a user would recognise, rewrite it.

---

## Verification before finishing

- [ ] `cd app/RemarcPackage && swift test` passes in full.
- [ ] A clean build succeeds: `rm -rf app/DerivedData` then `scripts/verify.sh build`. This proves the PopClip copy phase works from nothing. Note that nuking DerivedData fragments TCC microphone permissions for this bundle; if voice features stop working afterwards, run `tccutil reset Microphone com.metepolat.Remarc` and grant access again.
- [ ] `scripts/verify.sh smoke-test` passes, confirming the app is running and reached "AppController setup complete".
- [ ] `ls app/DerivedData/Build/Products/Debug/Remarc.app/Contents/Resources/Remarc.popclipext` shows the package intact after that clean build.
- [ ] The end-to-end round trip works in a native app and in Safari, with focus staying in the source app.
- [ ] Detection mode set to Hotkey Only shows no Remarc tooltip while the hotkey still works.
- [ ] `grep RemarcURLHandler /tmp/remarc_debug.log` shows the expected bundle path, confirming no misroute to another installed copy.

Then use `superpowers:finishing-a-development-branch` to decide how this merges.
