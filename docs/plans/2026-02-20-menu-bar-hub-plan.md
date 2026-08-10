# Menu Bar Hub Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace corner widget, mini-viewer, full viewer, and NSMenu dropdown with a menu bar popover + detachable window.

**Architecture:** All comment management moves into a single `PopoverContentView` hosted in either an NSPanel (anchored below the status item) or an NSWindow (detached mode). A shared `CommentEditorView` is used for both the tooltip-initiated capture flow and in-popover editing. The data model gains a `CommentReference` enum for future screenshot support, and storage moves from a flat `data.json` to a directory structure.

**Tech Stack:** SwiftUI + AppKit, NSPanel, NSHostingView, Combine, existing PersistenceManager/ExportManager/LicenseManager singletons.

**Design doc:** `docs/plans/2026-02-20-menu-bar-hub-design.md`

---

## Phase 1: Data Model & Storage Foundation

### Task 1: Add CommentReference enum and migrate storage

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentReference.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

**Step 1: Create CommentReference enum**

Create `Models/CommentReference.swift`:

```swift
import Foundation

/// Polymorphic reference type for comments.
/// MVP: only .textSelection is used.
/// Future: .screenshot will reference an image file by UUID.
public enum CommentReference: Codable, Equatable, Sendable {
    case textSelection(text: String)
    case quickNote

    /// Display text for the reference container in cards.
    public var displayText: String? {
        switch self {
        case .textSelection(let text): return text
        case .quickNote: return nil
        }
    }

    public var isQuickNote: Bool {
        if case .quickNote = self { return true }
        return false
    }
}
```

**Step 2: Update Comment model to use CommentReference**

In `Models/Comment.swift`, replace the `selectedText: String?` field with `reference: CommentReference`. Keep backward compatibility via custom `Codable` conformance so existing `data.json` files decode correctly:

```swift
public struct Comment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var reference: CommentReference     // replaces selectedText
    public var commentText: String
    public var source: String
    public var appBundleID: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var stackID: UUID
    public var isDeleted: Bool
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        reference: CommentReference,
        commentText: String,
        source: String,
        appBundleID: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        stackID: UUID,
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) { /* assign all fields */ }

    // Backward-compatible decoding: reads old `selectedText` field
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        commentText = try container.decode(String.self, forKey: .commentText)
        source = try container.decode(String.self, forKey: .source)
        appBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        stackID = try container.decode(UUID.self, forKey: .stackID)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)

        // Try new format first, fall back to old `selectedText` field
        if let ref = try? container.decode(CommentReference.self, forKey: .reference) {
            reference = ref
        } else if let text = try container.decodeIfPresent(String.self, forKey: .selectedText) {
            reference = .textSelection(text: text)
        } else {
            reference = .quickNote
        }
    }

    // Convenience computed properties for compatibility
    public var selectedText: String? { reference.displayText }
    public var isStandaloneNote: Bool { reference.isQuickNote }
    public var truncatedReference: String { /* same logic, using reference.displayText */ }

    private enum CodingKeys: String, CodingKey {
        case id, reference, selectedText, commentText, source, appBundleID
        case createdAt, updatedAt, stackID, isDeleted, deletedAt
    }
}
```

**Step 3: Migrate storage to directory structure**

In `PersistenceManager.init()`, change the file path from `data.json` to `comments.json` and create an `images/` directory:

```swift
let remarcDir = appSupport.appendingPathComponent("Remarc", isDirectory: true)
let imagesDir = remarcDir.appendingPathComponent("images", isDirectory: true)

// Create directories
if !FileManager.default.fileExists(atPath: remarcDir.path) {
    try? FileManager.default.createDirectory(at: remarcDir, withIntermediateDirectories: true)
}
if !FileManager.default.fileExists(atPath: imagesDir.path) {
    try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
}

// Migrate: if old data.json exists but comments.json doesn't, rename it
let oldFileURL = remarcDir.appendingPathComponent("data.json")
let newFileURL = remarcDir.appendingPathComponent("comments.json")
if FileManager.default.fileExists(atPath: oldFileURL.path)
    && !FileManager.default.fileExists(atPath: newFileURL.path) {
    try? FileManager.default.moveItem(at: oldFileURL, to: newFileURL)
    debugLog("PersistenceManager: Migrated data.json → comments.json")
}

self.fileURL = newFileURL
```

**Step 4: Update all callers of `createComment`**

In `PersistenceManager.createComment()`, change signature:

```swift
@discardableResult
public func createComment(
    reference: CommentReference,
    commentText: String,
    source: String,
    appBundleID: String?
) -> Comment?
```

Update `CommentInputController.saveComment()` to pass `reference:` instead of `selectedText:`:

```swift
let ref: CommentReference = if let text = selection?.text {
    .textSelection(text: text)
} else {
    .quickNote
}

let comment = PersistenceManager.shared.createComment(
    reference: ref,
    commentText: text,
    source: source,
    appBundleID: selection?.appBundleID
)
```

Update `ExportManager` methods that access `comment.selectedText` to use `comment.reference.displayText`.

**Step 5: Update Constants for new popover dimensions**

Add to `AppConstants`:

```swift
// Menu bar popover
public static let popoverWidth: CGFloat = 380
public static let popoverMaxHeightRatio: CGFloat = 0.5  // 50% of screen
public static let cardCornerRadius: CGFloat = 10
public static let editorWidth: CGFloat = 440
```

**Step 6: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`

Expected: Clean build. Existing data loads correctly via backward-compatible decoder.

**Step 7: Commit**

```bash
git add -A && git commit -m "feat: add CommentReference enum and migrate storage to directory structure"
```

---

## Phase 2: Menu Bar Popover Infrastructure

### Task 2: Create MenuBarPopoverController

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/MenuBarPopoverController.swift`

**Step 1: Create the popover panel controller**

This creates an NSPanel anchored below the status item (not NSPopover — gives us full control over sizing, material, and the floating editor overlay). The panel has:
- Material background, rounded corners, shadow
- Positioned below the status bar item
- Dismisses on click outside
- Arrow/triangle pointing up to the status item (optional — can skip for v1)

```swift
import AppKit
import SwiftUI
import Combine

@MainActor
public final class MenuBarPopoverController: ObservableObject {
    public static let shared = MenuBarPopoverController()

    @Published public var isVisible: Bool = false
    @Published public var isDetached: Bool = false

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // Reference to the status item button for positioning
    public var statusItemButton: NSStatusBarButton?

    public func toggle() {
        if isDetached {
            DetachedWindowController.shared.bringToFront()
            return
        }
        if isVisible { dismiss() } else { show() }
    }

    public func show() {
        guard !isDetached else {
            DetachedWindowController.shared.bringToFront()
            return
        }

        if panel == nil { createPanel() }
        positionBelowStatusItem()
        panel?.makeKeyAndOrderFront(nil)
        isVisible = true
        installClickOutsideMonitor()
    }

    public func dismiss() {
        panel?.orderOut(nil)
        isVisible = false
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.popoverWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSApp.effectiveAppearance

        let contentView = PopoverContentView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionBelowStatusItem() {
        guard let panel = panel, let button = statusItemButton,
              let buttonWindow = button.window else { return }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxHeight = screen.visibleFrame.height * AppConstants.popoverMaxHeightRatio

        // Recalculate panel height (capped at maxHeight)
        let panelHeight = min(panel.frame.height, maxHeight)
        let x = screenFrame.midX - (AppConstants.popoverWidth / 2)
        let y = screenFrame.minY - panelHeight - 4  // 4pt gap below menu bar

        // Clamp horizontally
        let clampedX = max(screen.visibleFrame.minX + 8,
                          min(x, screen.visibleFrame.maxX - AppConstants.popoverWidth - 8))

        panel.setFrame(NSRect(x: clampedX, y: y,
                             width: AppConstants.popoverWidth, height: panelHeight),
                      display: true)
    }

    private func installClickOutsideMonitor() { /* same pattern as CommentInputController */ }
    private func removeClickOutsideMonitor() { /* remove global monitor */ }
}
```

**Step 2: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`

Expected: Clean build. Controller compiles but isn't wired yet.

**Step 3: Commit**

```bash
git add -A && git commit -m "feat: add MenuBarPopoverController with NSPanel positioning"
```

### Task 3: Wire popover to AppController, replace NSMenu

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

**Step 1: Replace NSMenu with popover toggle on left-click**

In `AppController.setupMenuBar()`:
- Change `statusItem` length from `squareLength` to `variableLength` (to accommodate badge)
- Remove `statusItem?.menu = menu` (no more NSMenu)
- Add a button action for left-click → `MenuBarPopoverController.shared.toggle()`
- Add right-click handler for utility menu (via `NSEvent.addLocalMonitorForEvents`)
- Store reference: `MenuBarPopoverController.shared.statusItemButton = statusItem?.button`

```swift
private func setupMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem?.button {
        button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Remarc")
        button.image?.size = NSSize(width: 18, height: 18)
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    MenuBarPopoverController.shared.statusItemButton = statusItem?.button
}

@objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
        showUtilityMenu()
    } else {
        MenuBarPopoverController.shared.toggle()
    }
}
```

**Step 2: Create right-click utility menu**

```swift
private func showUtilityMenu() {
    let menu = NSMenu()

    let copyAllItem = NSMenuItem(title: "Copy All", action: #selector(copyAllAsMarkdown), keyEquivalent: "")
    copyAllItem.target = self
    copyAllItem.isEnabled = !PersistenceManager.shared.activeComments.isEmpty
    menu.addItem(copyAllItem)

    let quickNoteItem = NSMenuItem(title: "New Quick Note", action: #selector(newQuickNote), keyEquivalent: "")
    quickNoteItem.target = self
    menu.addItem(quickNoteItem)

    menu.addItem(NSMenuItem.separator())

    if MenuBarPopoverController.shared.isDetached {
        let reattachItem = NSMenuItem(title: "Re-attach Comments Window", action: #selector(reattachWindow), keyEquivalent: "")
        reattachItem.target = self
        menu.addItem(reattachItem)
    } else {
        let detachItem = NSMenuItem(title: "Detach Comments Window", action: #selector(detachWindow), keyEquivalent: "")
        detachItem.target = self
        menu.addItem(detachItem)
    }

    menu.addItem(NSMenuItem.separator())

    let pauseItem = NSMenuItem(
        title: SettingsManager.shared.isPaused ? "Resume" : "Pause",
        action: #selector(togglePause), keyEquivalent: ""
    )
    pauseItem.target = self
    menu.addItem(pauseItem)

    let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
    prefsItem.target = self
    menu.addItem(prefsItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "Quit Remarc", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil  // Remove immediately so left-click works again
}
```

**Step 3: Remove NSMenuDelegate conformance**

Remove `NSMenuDelegate` protocol, `menuWillOpen`, `rebuildMenu`, and all the menu-building helper methods (`addLicenseSection`, `addOutputFormatSubmenu`, `addExportItems`, `addCommentHistorySubmenu`). These are replaced by the popover UI and right-click menu.

**Step 4: Remove CornerWidget initialization from `completeSetup`**

Replace:
```swift
if !PersistenceManager.shared.activeStacks.isEmpty {
    CornerWidgetWindowController.shared.show()
}
```
With nothing — the corner widget no longer exists.

**Step 5: Update `openViewer()` to open popover instead**

Replace:
```swift
@objc private func openViewer() {
    ViewerWindowController.shared.show()
}
```
With:
```swift
@objc private func openViewer() {
    MenuBarPopoverController.shared.show()
}
```

The keyboard shortcut (Cmd+Shift+V) should now toggle the popover.

**Step 6: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`

Expected: Build succeeds. Left-clicking menu bar icon shows the popover panel (currently empty). Right-click shows utility menu. Note: some `@objc` methods like `detachWindow`, `reattachWindow`, `showPreferences` may not exist yet — add stub implementations that just call `debugLog`.

**Step 7: Verify with toolkit**

```bash
scripts/verify.sh launch
scripts/verify.sh ax list-windows
```

Expected: Popover panel appears as a window when clicking the status item.

**Step 8: Commit**

```bash
git add -A && git commit -m "feat: wire menu bar popover, replace NSMenu with left-click toggle + right-click utility menu"
```

---

## Phase 3: Popover Content View

### Task 4: Create PopoverContentView shell with header, empty state, footer

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Build the PopoverContentView**

This is the main content view used in both the popover panel and the detached window. It observes `PersistenceManager.appState` to reactively update.

```swift
import SwiftUI

struct PopoverContentView: View {
    @ObservedObject private var persistence = PersistenceManager.shared
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var sortNewestFirst: Bool = true

    private var comments: [Comment] {
        let active = persistence.activeComments
        let sorted = sortNewestFirst
            ? active.sorted { $0.createdAt > $1.createdAt }
            : active.sorted { $0.createdAt < $1.createdAt }
        if searchText.isEmpty { return sorted }
        let query = searchText.lowercased()
        return sorted.filter {
            ($0.reference.displayText?.lowercased().contains(query) ?? false)
            || $0.commentText.lowercased().contains(query)
            || $0.source.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if comments.isEmpty && !isSearching {
                emptyStateView
            } else {
                cardListView
            }
            if !persistence.activeComments.isEmpty {
                Divider()
                footerView
            }
        }
        .frame(width: AppConstants.popoverWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppConstants.panelCornerRadius, style: .continuous))
        .overlay(/* border stroke */)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    // -- Subviews defined in subsequent steps --
}
```

**Step 2: Build header view**

```swift
@ViewBuilder
private var headerView: some View {
    if isSearching {
        searchHeaderView
    } else {
        normalHeaderView
    }
}

private var normalHeaderView: some View {
    HStack {
        Text("Comments")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
        Spacer()
        // Icons only shown when comments exist
        if !persistence.activeComments.isEmpty {
            headerButton(icon: "magnifyingglass") { isSearching = true }
            headerButton(icon: sortNewestFirst ? "arrow.down" : "arrow.up") {
                sortNewestFirst.toggle()
            }
        }
        headerButton(icon: "note.text.badge.plus") {
            // Quick note via floating editor — wired in Task 10
        }
        headerButton(icon: "gearshape") {
            PreferencesWindowController.shared.show()
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
}

private var searchHeaderView: some View {
    HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
        TextField("Search comments...", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        Button(action: { isSearching = false; searchText = "" }) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
}

private func headerButton(icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

**Step 3: Build empty state view**

```swift
private var emptyStateView: some View {
    VStack(spacing: 12) {
        Spacer()
        Image(systemName: "text.bubble")
            .font(.system(size: 32))
            .foregroundStyle(.quaternary)
        Text("Select text and click Comment\nto get started")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        Spacer()
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
}
```

**Step 4: Build card list placeholder**

```swift
private var cardListView: some View {
    ScrollView {
        LazyVStack(spacing: 8) {
            ForEach(comments) { comment in
                CommentCardView(comment: comment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .frame(maxHeight: .infinity)
}
```

**Step 5: Build footer view**

```swift
private var footerView: some View {
    HStack(spacing: 12) {
        footerButton(title: "Copy All", icon: "doc.on.doc") {
            copyAll()
        }
        footerButton(title: "Delete All", icon: "trash") {
            // Delete all — wired with confirmation in Task 8
        }
        footerButton(title: "Export...", icon: "square.and.arrow.up") {
            exportToFile()
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
}

private func footerButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
}
```

**Step 6: Build and verify**

Build, launch, take screenshot of the popover to verify layout.

**Step 7: Commit**

```bash
git add -A && git commit -m "feat: add PopoverContentView with header, empty state, card list, and footer"
```

### Task 5: Create CommentCardView

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

**Step 1: Build the card view**

Each card is a rounded rect with shadow. Contains:
1. Reference container (inset background, 2-line truncation)
2. Comment text (4-line truncation, expandable)
3. Metadata (app + date)
4. Action buttons (hover/focus reveal)

```swift
import SwiftUI

struct CommentCardView: View {
    let comment: Comment
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @State private var needsExpansion: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reference container
            referenceView

            // Comment text
            commentTextView

            // Metadata
            metadataView
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.7))
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                cardActions
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // -- Reference container --
    @ViewBuilder
    private var referenceView: some View {
        if let text = comment.reference.displayText {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                )
        } else {
            Label("Quick Note", systemImage: "note.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // -- Comment text with expand/collapse --
    private var commentTextView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.commentText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 4)
                .background(GeometryReader { geo in
                    Color.clear.onAppear {
                        // Detect if text is truncated (heuristic: > 4 lines at ~16pt line height)
                        needsExpansion = geo.size.height > 64
                    }
                })

            if needsExpansion {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // -- Metadata --
    private var metadataView: some View {
        Text("\(comment.source) — \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    // -- Hover actions --
    private var cardActions: some View {
        HStack(spacing: 4) {
            cardActionButton(icon: "doc.on.doc", tooltip: "Copy") {
                ExportManager.shared.copyCommentToClipboard(comment)
                // TODO: show toast
            }
            cardActionButton(icon: "pencil", tooltip: "Edit") {
                // Opens floating editor — wired in Task 10
            }
            cardActionButton(icon: "trash", tooltip: "Delete") {
                // Delete with confirmation — wired in Task 8
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
    }

    private func cardActionButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
```

**Step 2: Build and verify**

Build. Create a test comment manually (launch app, select text, comment). Open popover. Take screenshot of card rendering.

**Step 3: Commit**

```bash
git add -A && git commit -m "feat: add CommentCardView with reference, expandable text, metadata, and hover actions"
```

---

## Phase 4: Card Actions & Interactions

### Task 6: Add toast system

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/ToastView.swift`

**Step 1: Create a reusable toast overlay**

A simple toast that appears at the bottom of the popover, auto-dismisses after a delay, and optionally has an "Undo" button.

```swift
import SwiftUI

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    var currentToast: ToastItem?

    struct ToastItem: Identifiable {
        let id = UUID()
        let message: String
        var undoAction: (() -> Void)?
        var duration: TimeInterval = 2.0
    }

    func show(_ message: String, undo: (() -> Void)? = nil, duration: TimeInterval = 2.0) {
        currentToast = ToastItem(message: message, undoAction: undo, duration: duration)
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if currentToast?.id == currentToast?.id {
                currentToast = nil
            }
        }
    }

    func dismiss() {
        currentToast = nil
    }
}

struct ToastOverlay: View {
    let toast: ToastManager.ToastItem

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            if let undo = toast.undoAction {
                Button("Undo") { undo(); ToastManager.shared.dismiss() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
```

**Step 2: Add toast overlay to PopoverContentView**

In `PopoverContentView.body`, wrap the VStack in a ZStack and add:

```swift
.overlay(alignment: .bottom) {
    if let toast = ToastManager.shared.currentToast {
        ToastOverlay(toast: toast)
            .padding(.bottom, 60)  // above sticky footer
    }
}
.animation(.easeInOut(duration: 0.2), value: ToastManager.shared.currentToast?.id)
```

**Step 3: Commit**

```bash
git add -A && git commit -m "feat: add ToastManager and ToastOverlay for in-popover notifications"
```

### Task 7: Wire card actions (copy, delete with confirmation, real-time updates)

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Wire copy action with toast**

In `CommentCardView`, update the copy action:

```swift
cardActionButton(icon: "doc.on.doc", tooltip: "Copy") {
    ExportManager.shared.copyCommentToClipboard(comment)
    ToastManager.shared.show("Copied to clipboard")
}
```

**Step 2: Wire delete action with confirmation popover**

Add state to `CommentCardView`:

```swift
@State private var showDeleteConfirmation: Bool = false
```

Update the delete button:

```swift
cardActionButton(icon: "trash", tooltip: "Delete") {
    showDeleteConfirmation = true
}
.popover(isPresented: $showDeleteConfirmation, arrowEdge: .bottom) {
    VStack(spacing: 8) {
        Text("Delete this comment?")
            .font(.system(size: 12, weight: .medium))
        HStack(spacing: 8) {
            Button("Cancel") { showDeleteConfirmation = false }
                .font(.system(size: 12))
                .buttonStyle(.plain)
            Button("Delete") {
                let commentID = comment.id
                PersistenceManager.shared.deleteComment(commentID)
                showDeleteConfirmation = false
                ToastManager.shared.show("Deleted", undo: {
                    if let stackID = PersistenceManager.shared.appState.activeStackID {
                        PersistenceManager.shared.restoreComment(commentID, to: stackID)
                    }
                }, duration: 5.0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red)
            .buttonStyle(.plain)
        }
    }
    .padding(12)
}
```

**Step 3: Wire footer Copy All with clear prompt**

In `PopoverContentView`, add state:

```swift
@State private var showClearPrompt: Bool = false
```

Update `copyAll()`:

```swift
private func copyAll() {
    guard let stack = persistence.activeStack else { return }
    let comments = persistence.activeComments
    ExportManager.shared.copyStackToClipboard(stack, comments: comments, format: .markdown)
    ToastManager.shared.show("Copied \(comments.count) comments")
    showClearPrompt = true
}
```

Add clear prompt as an overlay or inline footer state change:

```swift
if showClearPrompt {
    HStack {
        Text("Clear exported comments?")
            .font(.system(size: 11))
        Spacer()
        Button("Keep") { showClearPrompt = false }
            .font(.system(size: 11))
            .buttonStyle(.plain)
        Button("Clear") {
            if let stackID = persistence.appState.activeStackID {
                persistence.clearAllComments(in: stackID)
            }
            showClearPrompt = false
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.red)
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
}
```

**Step 4: Wire footer Delete All with confirmation**

Same confirmation popover pattern as single-card delete, but anchored to the Delete All button. Include undo toast that restores all comments.

**Step 5: Wire footer Export to File**

```swift
private func exportToFile() {
    guard let stack = persistence.activeStack else { return }
    let comments = persistence.activeComments
    ExportManager.shared.saveStackToFile(stack, comments: comments, format: SettingsManager.shared.outputFormat)
    showClearPrompt = true
}
```

**Step 6: Build, test all card actions, take screenshots**

Verify: copy shows toast, delete shows popover confirmation then undo toast, Copy All prompts to clear, Delete All has confirmation.

**Step 7: Commit**

```bash
git add -A && git commit -m "feat: wire card and footer actions with confirmations, toasts, and clear prompts"
```

### Task 8: Add keyboard navigation

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

**Step 1: Add focused comment tracking**

In `PopoverContentView`, add:

```swift
@State private var focusedCommentID: UUID?
```

Pass to each card:

```swift
CommentCardView(
    comment: comment,
    isFocused: focusedCommentID == comment.id,
    onFocusChange: { focusedCommentID = $0 ? comment.id : nil }
)
```

**Step 2: Handle arrow key navigation**

The NSPanel hosting this view needs to forward key events. Add a `keyDown` handler in `MenuBarPopoverController`'s panel subclass that posts notifications, or use SwiftUI's `.onKeyPress` (macOS 14+):

```swift
.onKeyPress(.downArrow) {
    moveFocus(direction: 1)
    return .handled
}
.onKeyPress(.upArrow) {
    moveFocus(direction: -1)
    return .handled
}

private func moveFocus(direction: Int) {
    let list = comments
    guard !list.isEmpty else { return }
    if let current = focusedCommentID,
       let idx = list.firstIndex(where: { $0.id == current }) {
        let newIdx = max(0, min(list.count - 1, idx + direction))
        focusedCommentID = list[newIdx].id
    } else {
        focusedCommentID = direction > 0 ? list.first?.id : list.last?.id
    }
}
```

**Step 3: Make focused card reveal actions**

In `CommentCardView`, treat `isFocused` the same as `isHovered`:

```swift
let showActions = isHovered || isFocused
```

**Step 4: Build and verify keyboard navigation**

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add keyboard navigation for comment cards in popover"
```

---

## Phase 5: Floating Editor Panel

### Task 9: Create shared CommentEditorView

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentEditorView.swift`

**Step 1: Create the shared editor view**

This view is used in three contexts:
1. Near text selection (comment input after tooltip click)
2. Floating on top of popover (edit existing / quick note)
3. (Future) Detached window editor

```swift
import SwiftUI

struct CommentEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var commentText: String
    @FocusState private var isFocused: Bool

    /// Read-only reference text. Nil for quick notes.
    let referenceText: String?
    let sourceName: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reference (read-only)
            if let ref = referenceText {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(ref)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .lineLimit(3)
                    }
                    if let source = sourceName {
                        Text(source)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                )
            } else {
                Label("Quick Note", systemImage: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Text editor
            CommentTextEditor(
                text: $commentText,
                onSubmit: { onSave(commentText) },
                onCancel: onCancel
            )
            .focused($isFocused)
            .frame(minHeight: 60, maxHeight: 200)

            // Footer
            HStack {
                Text("Enter to save, Shift+Enter for newline")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Button(action: { onSave(commentText) }) {
                    Text("Save")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            AdaptiveColors.brandGradient(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .onAppear { isFocused = true }
    }
}
```

**Step 2: Commit**

```bash
git add -A && git commit -m "feat: create shared CommentEditorView for input and editing contexts"
```

### Task 10: Create FloatingEditorController

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/FloatingEditorController.swift`

**Step 1: Create the controller**

This manages the floating editor panel that appears on top of the popover. It dims the popover and blocks its interaction.

```swift
import AppKit
import SwiftUI

@MainActor
public final class FloatingEditorController: ObservableObject {
    public static let shared = FloatingEditorController()

    @Published public var isVisible: Bool = false

    private var panel: NSPanel?
    private var dimOverlay: NSPanel?  // Overlay on top of the popover to block interaction

    /// Show editor for editing an existing comment
    public func showForEdit(comment: Comment) {
        show(
            referenceText: comment.reference.displayText,
            sourceName: comment.source,
            initialText: comment.commentText,
            onSave: { newText in
                PersistenceManager.shared.updateComment(comment.id, text: newText)
                self.dismiss()
            }
        )
    }

    /// Show editor for creating a quick note
    public func showForQuickNote() {
        show(
            referenceText: nil,
            sourceName: nil,
            initialText: "",
            onSave: { text in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.dismiss()
                    return
                }
                PersistenceManager.shared.createComment(
                    reference: .quickNote,
                    commentText: text,
                    source: "Quick Note",
                    appBundleID: nil
                )
                LicenseManager.shared.recordComment()
                self.dismiss()
            }
        )
    }

    public func dismiss() {
        panel?.orderOut(nil)
        dimOverlay?.orderOut(nil)
        isVisible = false
    }

    private func show(referenceText: String?, sourceName: String?, initialText: String, onSave: @escaping (String) -> Void) {
        // Create dim overlay on popover
        installDimOverlay()

        // Create or reconfigure editor panel
        let editorView = CommentEditorView(
            commentText: .constant(initialText),  // Need @State wrapper — see step 2
            referenceText: referenceText,
            sourceName: sourceName,
            onSave: onSave,
            onCancel: { [weak self] in self?.dismiss() }
        )
        // ... create NSPanel, position adjacent to popover, show
        isVisible = true
    }

    private func installDimOverlay() {
        // Create a transparent panel that covers the popover area
        // with a semi-transparent black fill, at a window level
        // between the popover and the editor
    }
}
```

Note: The `@Binding var commentText` in `CommentEditorView` needs to be driven by local `@State` in a wrapper. Create a small wrapper view:

```swift
struct FloatingEditorWrapper: View {
    @State private var text: String
    let referenceText: String?
    let sourceName: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialText: String, referenceText: String?, sourceName: String?, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initialText)
        self.referenceText = referenceText
        self.sourceName = sourceName
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        CommentEditorView(
            commentText: $text,
            referenceText: referenceText,
            sourceName: sourceName,
            onSave: onSave,
            onCancel: onCancel
        )
        .frame(width: AppConstants.editorWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppConstants.panelCornerRadius, style: .continuous))
        .overlay(/* border */)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
    }
}
```

**Step 2: Wire edit action in CommentCardView**

```swift
cardActionButton(icon: "pencil", tooltip: "Edit") {
    FloatingEditorController.shared.showForEdit(comment: comment)
}
```

**Step 3: Wire quick note button in PopoverContentView header**

```swift
headerButton(icon: "note.text.badge.plus") {
    FloatingEditorController.shared.showForQuickNote()
}
```

**Step 4: Build and verify editor shows on top of dimmed popover**

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add FloatingEditorController with dim overlay for in-popover editing"
```

### Task 11: Update CommentInputController to use shared CommentEditorView

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`

**Step 1: Refactor CommentInputView to use CommentEditorView**

Replace the body of `CommentInputView` to wrap `CommentEditorView`:

```swift
struct CommentInputView: View {
    @EnvironmentObject var controller: CommentInputController
    @State private var commentText: String = ""

    var body: some View {
        CommentEditorView(
            commentText: $commentText,
            referenceText: controller.currentSelection?.text,
            sourceName: controller.currentSelection?.truncatedSource,
            onSave: { controller.saveComment(text: $0) },
            onCancel: { controller.dismiss() }
        )
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppConstants.panelCornerRadius, style: .continuous))
        .overlay(/* border stroke */)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remarc.commentInput")
        .onAppear { commentText = "" }
        .onChange(of: controller.textResetToken) { commentText = "" }
        .onChange(of: commentText) { controller.currentText = commentText }
    }
}
```

**Step 2: Update CommentInputController.saveComment to use CommentReference**

Already done in Task 1. Verify it uses `reference:` parameter.

**Step 3: Remove CornerWidgetWindowController.shared.show() from saveComment**

The save comment method currently calls `CornerWidgetWindowController.shared.show()`. Remove that line — the menu bar badge handles feedback now.

**Step 4: Build and verify tooltip → comment input still works**

**Step 5: Commit**

```bash
git add -A && git commit -m "refactor: update CommentInputView to use shared CommentEditorView"
```

---

## Phase 6: Menu Bar Badge & Save Animation

### Task 12: Add badge to menu bar icon and save animation

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

**Step 1: Create a badge view for the status item**

NSStatusItem buttons support custom views. Create a small NSView subclass that renders the SF Symbol + badge:

```swift
private class StatusItemBadgeView: NSView {
    var count: Int = 0 { didSet { needsDisplay = true } }
    var isPaused: Bool = false { didSet { needsDisplay = true } }
    private var pulseAnimation: Bool = false

    override var intrinsicContentSize: NSSize {
        // Icon (18pt) + gap (4pt) + badge (variable width)
        let badgeWidth = count > 0 ? max(18, CGFloat(String(count).count) * 8 + 10) : 0
        let totalWidth = 18 + (count > 0 ? 4 + badgeWidth : 0)
        return NSSize(width: totalWidth, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw SF Symbol
        let icon = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Remarc")!
        icon.size = NSSize(width: 16, height: 16)
        let iconRect = NSRect(x: 1, y: 3, width: 16, height: 16)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver,
                  fraction: isPaused ? 0.4 : 1.0)

        // Draw badge if count > 0
        guard count > 0 else { return }
        let badgeText = "\(count)"
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white
        ]
        let textSize = (badgeText as NSString).size(withAttributes: attrs)
        let badgeWidth = max(16, textSize.width + 8)
        let badgeHeight: CGFloat = 14
        let badgeX = 18 + 4
        let badgeY = (bounds.height - badgeHeight) / 2

        let badgePath = NSBezierPath(roundedRect: NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight),
                                     xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
        // Use brand color (teal/blue)
        NSColor(red: 0.2, green: 0.7, blue: 0.85, alpha: 1.0).setFill()
        badgePath.fill()

        let textX = badgeX + (badgeWidth - textSize.width) / 2
        let textY = badgeY + (badgeHeight - textSize.height) / 2
        (badgeText as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
    }

    func pulse() {
        // Scale animation on the badge: scale up 1.2x then back to 1.0x over 0.3s
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 1.3, 1.0]
        anim.keyTimes = [0, 0.4, 1.0]
        anim.duration = 0.35
        layer?.add(anim, forKey: "pulse")
    }
}
```

**Step 2: Wire badge into AppController**

In `setupMenuBar()`, use the custom view:

```swift
let badgeView = StatusItemBadgeView()
statusItem?.button?.addSubview(badgeView)
// or use statusItem?.button?.image = nil and draw custom
```

Alternative simpler approach: use `statusItem?.button?.title` with an attributed string that includes the badge as a colored background. This may be simpler than custom drawing. Choose whichever approach renders correctly in the menu bar.

**Step 3: Observe comment count changes**

```swift
PersistenceManager.shared.$appState
    .map { $0.comments.filter { !$0.isDeleted }.count }
    .removeDuplicates()
    .receive(on: DispatchQueue.main)
    .sink { [weak self] count in
        self?.badgeView.count = count
        self?.badgeView.invalidateIntrinsicContentSize()
    }
    .store(in: &cancellables)
```

**Step 4: Add save animation**

In `CommentInputController.saveComment()`, after creating the comment:

1. Animate the panel with a scale-down + fade (macOS window dismiss feel):

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = 0.25
    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
    panel?.animator().alphaValue = 0
    panel?.animator().setFrame(
        panel!.frame.insetBy(dx: 20, dy: 20), display: true
    )
} completionHandler: {
    self.panel?.orderOut(nil)
    self.panel?.alphaValue = 1  // Reset for next show
    // Pulse the badge
    badgeView.pulse()
}
```

2. Notify AppController to pulse the badge (via NotificationCenter or direct reference).

**Step 5: Build and verify**

- Check badge shows correct count
- Check badge disappears at 0
- Check save animation looks smooth
- Take screenshots

**Step 6: Commit**

```bash
git add -A && git commit -m "feat: add menu bar badge with comment count and save animation"
```

---

## Phase 7: Detached Window

### Task 13: Create DetachedWindowController

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/DetachedWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/MenuBarPopoverController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

**Step 1: Create the detached window controller**

```swift
import AppKit
import SwiftUI

@MainActor
public final class DetachedWindowController: ObservableObject {
    public static let shared = DetachedWindowController()

    @Published public var isVisible: Bool = false
    @Published public var isPinned: Bool = false

    private var window: NSWindow?

    public func show() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
        MenuBarPopoverController.shared.isDetached = true
    }

    public func dismiss() {
        window?.orderOut(nil)
        isVisible = false
        MenuBarPopoverController.shared.isDetached = false
    }

    public func bringToFront() {
        if isVisible {
            if window?.isKeyWindow == true {
                window?.orderOut(nil)
                isVisible = false
            } else {
                window?.makeKeyAndOrderFront(nil)
            }
        } else {
            show()
        }
    }

    public func togglePin() {
        isPinned.toggle()
        window?.level = isPinned ? .floating : .normal
        window?.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    private func createWindow() {
        let contentView = DetachedWindowContentView(onPin: { [weak self] in self?.togglePin() })
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.popoverWidth + 20, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Remarc Comments"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.delegate = self  // Handle windowWillClose → reattach

        self.window = window
    }
}

extension DetachedWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isVisible = false
        MenuBarPopoverController.shared.isDetached = false
    }
}

struct DetachedWindowContentView: View {
    let onPin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Pin button in a toolbar area
            HStack {
                Spacer()
                Button(action: onPin) {
                    Image(systemName: DetachedWindowController.shared.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(DetachedWindowController.shared.isPinned ? "Unpin from top" : "Pin on top")
                .padding(.trailing, 8)
                .padding(.top, 4)
            }

            // Same content view as popover
            PopoverContentView()
        }
    }
}
```

**Step 2: Wire detach/reattach in AppController**

```swift
@objc private func detachWindow() {
    MenuBarPopoverController.shared.dismiss()
    DetachedWindowController.shared.show()
}

@objc private func reattachWindow() {
    DetachedWindowController.shared.dismiss()
}
```

**Step 3: Update MenuBarPopoverController.toggle() for mutual exclusion**

Already handled in Task 2 — `toggle()` checks `isDetached` and calls `DetachedWindowController.shared.bringToFront()` instead.

**Step 4: Build and verify**

- Right-click → Detach → window appears
- Left-click menu bar → brings window to front / hides
- Right-click → Re-attach → window closes, popover works again
- Pin toggle works
- Close button reattaches

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add DetachedWindowController with pin, mutual exclusion, and reattach"
```

---

## Phase 8: Preferences Window

### Task 14: Create PreferencesWindowController

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Create a tabbed preferences window**

Standard macOS preferences window with tabs: General, Export, Excluded Apps, License.

```swift
import AppKit
import SwiftUI

@MainActor
public final class PreferencesWindowController {
    public static let shared = PreferencesWindowController()

    private var window: NSWindow?

    public func show() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let prefsView = PreferencesView()
        let hostingView = NSHostingView(rootView: prefsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Remarc Preferences"
        window.center()
        self.window = window
    }
}

struct PreferencesView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var selectedTab: PrefsTab = .general

    enum PrefsTab: String, CaseIterable {
        case general = "General"
        case export = "Export"
        case excludedApps = "Excluded Apps"
        case license = "License"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .export: return "square.and.arrow.up"
            case .excludedApps: return "app.dashed"
            case .license: return "key"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label(PrefsTab.general.rawValue, systemImage: PrefsTab.general.icon) }.tag(PrefsTab.general)
            exportTab.tabItem { Label(PrefsTab.export.rawValue, systemImage: PrefsTab.export.icon) }.tag(PrefsTab.export)
            excludedAppsTab.tabItem { Label(PrefsTab.excludedApps.rawValue, systemImage: PrefsTab.excludedApps.icon) }.tag(PrefsTab.excludedApps)
            licenseTab.tabItem { Label(PrefsTab.license.rawValue, systemImage: PrefsTab.license.icon) }.tag(PrefsTab.license)
        }
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            Toggle("Pause selection detection", isOn: $settings.isPaused)
            // Selection detection mode picker if needed
        }
    }

    private var exportTab: some View {
        Form {
            Picker("Default format", selection: $settings.outputFormat) {
                ForEach(SettingsManager.OutputFormat.allCases, id: \.self) { format in
                    Text(format.label).tag(format)
                }
            }
            Toggle("Include metadata in exports", isOn: $settings.includeMetadataInExport)
        }
    }

    private var excludedAppsTab: some View {
        // Reuse content from ExcludeListWindowController or embed it here.
        // For now, a button that opens the existing exclude list window.
        VStack {
            Text("Apps where Remarc won't show the comment tooltip.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Manage Excluded Apps...") {
                ExcludeListWindowController.shared.show()
            }
        }
    }

    private var licenseTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Show license state
            // Button to enter key or upgrade
            // Reuse LicenseEntryWindowController.show() for key entry
            Text("License status: \(licenseDescription)")
                .font(.system(size: 12))
            Button("Enter License Key...") {
                LicenseEntryWindowController.shared.show()
            }
            Button("Upgrade to Pro") {
                LicenseManager.shared.openCheckout()
            }
        }
    }

    private var licenseDescription: String {
        switch LicenseManager.shared.licenseState {
        case .free(let n): return "Free (\(n) comments remaining)"
        case .licensed: return "Pro (active)"
        case .expired: return "Expired"
        case .invalid: return "Invalid"
        }
    }
}
```

**Step 2: Wire gear icon in PopoverContentView header**

Already done in Task 4 — `PreferencesWindowController.shared.show()`.

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add -A && git commit -m "feat: add PreferencesWindowController with General, Export, Excluded Apps, and License tabs"
```

---

## Phase 9: Tooltip Restyle

### Task 15: Restyle tooltip to match new design language

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipWindowController.swift`

**Step 1: Update tooltip visual design**

Match the card aesthetic — consistent shadow, border, rounded corners, typography:

- Update the background material to match card style
- Use same shadow values as comment cards
- Update border stroke to match
- Refine typography (font weight, size)
- Keep same functionality — just visual refresh

**Step 2: Build, launch, select text, take screenshot of tooltip**

Use the verification toolkit:
```bash
scripts/verify.sh build && scripts/verify.sh launch
# Select text, wait for tooltip
FRAME=$(scripts/verify.sh ax frame --identifier remarc.tooltip)
screencapture -R "$FRAME" tests/screenshots/tooltip-restyle.png
```
View the screenshot with Read tool.

**Step 3: Commit**

```bash
git add -A && git commit -m "style: restyle tooltip to match new card-based design language"
```

---

## Phase 10: Cleanup

### Task 16: Remove CornerWidget

**Files:**
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Views/CornerWidgetWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift` (remove all references)
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift` (remove `CornerWidgetWindowController.shared.show()` in `saveComment`)

**Step 1: Delete the file**

```bash
rm app/RemarcPackage/Sources/RemarcFeature/Views/CornerWidgetWindowController.swift
```

**Step 2: Remove all references**

Search for `CornerWidget` across the codebase and remove:
- `AppController.completeSetup()`: remove the `.show()` call (already done in Task 3)
- `CommentInputController.saveComment()`: remove `.show()` call (already done in Task 11)
- Any other references

**Step 3: Build and verify no compilation errors**

**Step 4: Commit**

```bash
git add -A && git commit -m "chore: remove CornerWidgetWindowController (replaced by menu bar popover)"
```

### Task 17: Remove ViewerWindow

**Files:**
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Views/ViewerWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift` (already done — `openViewer` now opens popover)

**Step 1: Delete the file**

```bash
rm app/RemarcPackage/Sources/RemarcFeature/Views/ViewerWindowController.swift
```

**Step 2: Remove all references**

Search for `ViewerWindowController` and `ViewerView` across codebase. Remove imports and usages.

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add -A && git commit -m "chore: remove ViewerWindowController (replaced by menu bar popover)"
```

### Task 18: Clean up old menu bar code

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

**Step 1: Remove dead code**

Remove all the old menu-building helpers that are no longer used:
- `rebuildMenu()` (if any remains)
- `addLicenseSection()`
- `addOutputFormatSubmenu()`
- `addExportItems()`
- `addCommentHistorySubmenu()`
- `NSMenuDelegate` conformance
- Individual export action methods that are now handled by PopoverContentView

Keep:
- `statusItemClicked` (new left/right click handler)
- `showUtilityMenu` (right-click menu)
- `togglePause`, `quitApp`, `showAbout` (still used)
- `newQuickNote` (used by right-click menu)

**Step 2: Remove unused constants**

In `AppConstants`, remove:
- `viewerWidth`, `viewerHeight` (viewer is gone)

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add -A && git commit -m "chore: remove dead menu-building code and unused constants"
```

---

## Phase 11: Integration & Verification

### Task 19: Full verification pass

**Files:** None created — verification only.

**Step 1: Build and launch**

```bash
scripts/verify.sh build
scripts/verify.sh launch
scripts/verify.sh ax click --identifier _NS:8  # Dismiss Sparkle alert
```

**Step 2: Verify all flows**

Verify each flow manually with screenshots:

1. **Empty state**: Open popover with 0 comments → illustration + help text, no search/sort icons
2. **Capture flow**: Select text → tooltip appears → click → comment input → type → Enter → badge increments
3. **Save animation**: Comment input shrinks + badge pulses
4. **Popover shows cards**: Open popover → cards with reference, text, metadata
5. **Card expand**: Click chevron on a long comment → text expands
6. **Card hover actions**: Hover a card → copy/edit/delete appear
7. **Copy action**: Click copy → toast appears
8. **Delete action**: Click delete → confirmation popover → confirm → undo toast
9. **Edit action**: Click edit → floating editor appears over dimmed popover → edit → save
10. **Quick note from header**: Click note icon → floating editor (no reference) → save
11. **Search**: Click search → header replaces → type → cards filter → clear → header restores
12. **Sort**: Click sort → order reverses
13. **Footer Copy All**: Click → copies → "Clear exported?" prompt
14. **Footer Delete All**: Click → confirmation → undo toast
15. **Footer Export**: Click → save dialog
16. **Detached window**: Right-click → Detach → window appears → left-click toggles visibility
17. **Pin**: Click pin → window stays on top
18. **Re-attach**: Right-click → Re-attach → window closes, popover works
19. **Preferences**: Click gear → preferences window opens
20. **Right-click menu**: All items work
21. **Keyboard shortcuts**: Cmd+Shift+V toggles popover, Cmd+Shift+C creates comment/quick note
22. **Keyboard navigation**: Arrow keys move focus, actions reveal on focused card

Take screenshots for each state using the verification toolkit.

**Step 3: Commit final state**

```bash
git add -A && git commit -m "feat: complete Menu Bar Hub redesign — all flows verified"
```

---

## Summary

| Phase | Tasks | Description |
|---|---|---|
| 1 | Task 1 | Data model + storage migration |
| 2 | Tasks 2-3 | Menu bar popover infrastructure |
| 3 | Tasks 4-5 | Popover content view + comment card |
| 4 | Tasks 6-8 | Toast system, card actions, keyboard navigation |
| 5 | Tasks 9-11 | Shared editor view, floating editor, input refactor |
| 6 | Task 12 | Menu bar badge + save animation |
| 7 | Task 13 | Detached window with pin |
| 8 | Task 14 | Preferences window |
| 9 | Task 15 | Tooltip restyle |
| 10 | Tasks 16-18 | Remove old surfaces + dead code |
| 11 | Task 19 | Full integration verification |
