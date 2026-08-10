# Screenshot Comments Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add native region screenshot capture with comments — users drag to select a screen region, capture it via ScreenCaptureKit, and attach a comment. Screenshots display as thumbnails in comment cards with click-to-preview and right-click copy/save.

**Architecture:** ScreenCaptureService manages a full-screen NSPanel overlay for rubber-band region selection, then calls `SCScreenshotManager.captureImage(in: CGRect)` to capture. Screen Recording permission is handled lazily via a CaAML-style permission panel with polling. Screenshots are saved as PNGs under `~/Library/Application Support/Remarc/images/` and referenced in CommentReference via a new `.screenshot(imagePath:)` case.

**Tech Stack:** Swift 6.0+, macOS 14.4+, ScreenCaptureKit (`SCScreenshotManager`), AppKit (NSPanel overlay), SwiftUI (thumbnail views), KeyboardShortcuts (screenshot hotkey)

**Design doc:** `docs/plans/2026-02-27-screenshot-comments-design.md`

---

### Task 1: Add `.screenshot` Case to CommentReference

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentReference.swift`

**Step 1: Add the screenshot case and update computed properties**

```swift
// CommentReference.swift — full replacement
import Foundation

public enum CommentReference: Codable, Equatable, Sendable {
    case textSelection(text: String)
    case quickNote
    case screenshot(imagePath: String)  // relative to App Support/Remarc/

    public var displayText: String? {
        switch self {
        case .textSelection(let text): return text
        case .quickNote: return nil
        case .screenshot: return nil
        }
    }

    public var isQuickNote: Bool {
        if case .quickNote = self { return true }
        return false
    }

    public var isScreenshot: Bool {
        if case .screenshot = self { return true }
        return false
    }

    public var imagePath: String? {
        if case .screenshot(let path) = self { return path }
        return nil
    }
}
```

**Step 2: Update Comment.swift truncatedReference**

In `Comment.swift:99-106`, update `truncatedReference` to handle screenshots:

```swift
public var truncatedReference: String {
    switch reference {
    case .textSelection(let text):
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if cleaned.count > AppConstants.maxReferenceTextLength {
            return String(cleaned.prefix(AppConstants.maxReferenceTextLength)) + "..."
        }
        return cleaned
    case .quickNote:
        return "Quick Note"
    case .screenshot:
        return "Screenshot"
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/CommentReference.swift app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift
git commit -m "feat: add .screenshot case to CommentReference"
```

---

### Task 2: Add Settings for Screenshot Feature

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

**Step 1: Add `copyScreenshotToClipboard` setting**

In `SettingsManager.swift`, add to `Keys` enum:
```swift
static let copyScreenshotToClipboard = "copyScreenshotToClipboard"
```

Add published property (after `normalizeWhitespace`):
```swift
@Published public var copyScreenshotToClipboard: Bool {
    didSet { defaults.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshotToClipboard) }
}
```

In `init()`, after the normalizeWhitespace initialization block:
```swift
self.copyScreenshotToClipboard = defaults.bool(forKey: Keys.copyScreenshotToClipboard)
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add copyScreenshotToClipboard setting"
```

---

### Task 3: Create ScreenRecordingPermissionController

Adapts the CaAML OnboardingWindowController pattern for Screen Recording permission.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/ScreenRecordingPermissionController.swift`

**Step 1: Create the permission controller**

```swift
import AppKit
import SwiftUI

/// State machine for Screen Recording permission flow
enum ScreenRecordingPermissionState: Equatable {
    case needsPermission
    case waitingForGrant
    case granted
}

@MainActor
final class ScreenRecordingPermissionController: NSObject, ObservableObject {
    static let shared = ScreenRecordingPermissionController()

    @Published private(set) var state: ScreenRecordingPermissionState = .needsPermission

    private var panel: NSPanel?
    private var pollingTimer: Timer?

    /// Callback when permission is resolved
    var onResult: ((_ granted: Bool) -> Void)?

    private override init() {
        super.init()
    }

    /// Check if Screen Recording permission is granted (no prompt, no side-effects)
    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Show the permission panel if needed. Calls onResult when resolved.
    func requestPermission(onResult: @escaping (_ granted: Bool) -> Void) {
        self.onResult = onResult

        if hasPermission() {
            state = .granted
            onResult(true)
            return
        }

        state = .needsPermission
        showPanel()
    }

    /// User clicks "Open System Settings"
    func openSystemSettings() {
        state = .waitingForGrant

        // Deep link to Screen Recording privacy pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }

        startPolling()
    }

    /// User clicks "Skip" / "Cancel"
    func skip() {
        stopPolling()
        dismissPanel()
        onResult?(false)
        onResult = nil
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.permissionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionStatus()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func checkPermissionStatus() {
        if hasPermission() {
            state = .granted
            stopPolling()
            dismissPanel()
            onResult?(true)
            onResult = nil
            debugLog("ScreenRecordingPermission: granted")
        }
    }

    // MARK: - Panel

    private func showPanel() {
        if panel == nil {
            let contentView = ScreenRecordingPermissionView()
                .environmentObject(self)

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Screen Recording Permission"
            panel.contentView = NSHostingView(rootView: contentView)
            panel.center()
            self.panel = panel
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
    }
}

// MARK: - SwiftUI View

struct ScreenRecordingPermissionView: View {
    @EnvironmentObject var controller: ScreenRecordingPermissionController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Screen Recording Permission")
                .font(.system(size: 16, weight: .semibold))

            Text("Remarc needs Screen Recording permission to capture screenshots. Open System Settings and enable Remarc in the Screen Recording list.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            switch controller.state {
            case .needsPermission:
                Button("Open System Settings") {
                    controller.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    controller.skip()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .waitingForGrant:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for permission...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") {
                    controller.skip()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .granted:
                Label("Permission granted!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/ScreenRecordingPermissionController.swift
git commit -m "feat: add Screen Recording permission controller (CaAML pattern)"
```

---

### Task 4: Create ScreenCaptureService — Region Selection Overlay

The core capture service. Full-screen NSPanel overlay with rubber-band selection, then `SCScreenshotManager.captureImage(in: CGRect)`.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/ScreenCaptureService.swift`

**Step 1: Create the service**

```swift
import AppKit
import ScreenCaptureKit

@MainActor
public final class ScreenCaptureService: ObservableObject {
    public static let shared = ScreenCaptureService()

    private var overlayPanel: NSPanel?
    private var overlayView: RegionSelectionView?
    private var onComplete: ((_ imagePath: String, _ captureRect: CGRect) -> Void)?
    private var onCancel: (() -> Void)?

    private init() {}

    // MARK: - Public API

    /// Start the screenshot capture flow. Checks permission first.
    /// - Parameters:
    ///   - onComplete: Called with relative image path and capture rect (screen coords) on success
    ///   - onCancel: Called if user cancels or permission denied
    public func startCapture(
        onComplete: @escaping (_ imagePath: String, _ captureRect: CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        if ScreenRecordingPermissionController.shared.hasPermission() {
            showOverlay()
        } else {
            ScreenRecordingPermissionController.shared.requestPermission { [weak self] granted in
                if granted {
                    self?.showOverlay()
                } else {
                    self?.onCancel?()
                    self?.cleanup()
                }
            }
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        guard let screen = NSScreen.main else {
            onCancel?()
            cleanup()
            return
        }

        let overlayView = RegionSelectionView(frame: screen.frame)
        overlayView.onRegionSelected = { [weak self] rect in
            self?.handleRegionSelected(rect, screen: screen)
        }
        overlayView.onCancelled = { [weak self] in
            self?.dismissOverlay()
            self?.onCancel?()
            self?.cleanup()
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = overlayView

        self.overlayPanel = panel
        self.overlayView = overlayView

        panel.makeKeyAndOrderFront(nil)
        debugLog("ScreenCaptureService: Overlay shown")
    }

    private func dismissOverlay() {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        overlayView = nil
        debugLog("ScreenCaptureService: Overlay dismissed")
    }

    // MARK: - Capture

    private func handleRegionSelected(_ rect: CGRect, screen: NSScreen) {
        dismissOverlay()

        // Convert from AppKit coordinates (bottom-left origin) to Quartz coordinates (top-left origin)
        let quartzRect = CGRect(
            x: rect.origin.x,
            y: screen.frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        debugLog("ScreenCaptureService: Region selected: \(quartzRect)")

        Task {
            do {
                let image = try await captureRegion(quartzRect)
                let imagePath = try saveImage(image)

                // Copy to clipboard if setting is enabled
                if SettingsManager.shared.copyScreenshotToClipboard {
                    copyImageToClipboard(image)
                }

                onComplete?(imagePath, rect)
                cleanup()
            } catch {
                debugLog("ScreenCaptureService: Capture failed — \(error)")
                onCancel?()
                cleanup()
            }
        }
    }

    private func captureRegion(_ rect: CGRect) async throws -> NSImage {
        // Get available content for the display
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * 2)  // Retina
        config.height = Int(rect.height * 2)
        config.showsCursor = false
        config.captureResolution = .best

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return NSImage(cgImage: cgImage, size: NSSize(width: rect.width, height: rect.height))
    }

    private func saveImage(_ image: NSImage) throws -> String {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }

        let uuid = UUID().uuidString
        let relativePath = "images/\(uuid).png"

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fullPath = appSupport.appendingPathComponent("Remarc/\(relativePath)")

        try pngData.write(to: fullPath)
        debugLog("ScreenCaptureService: Saved screenshot to \(relativePath)")
        return relativePath
    }

    private func copyImageToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        debugLog("ScreenCaptureService: Copied screenshot to clipboard")
    }

    private func cleanup() {
        onComplete = nil
        onCancel = nil
    }

    enum CaptureError: Error {
        case noDisplay
        case encodingFailed
    }
}

// MARK: - Region Selection View

/// Full-screen NSView for rubber-band region selection.
/// Dark semi-transparent background with clear cutout for selected region.
private class RegionSelectionView: NSView {
    var onRegionSelected: ((_ rect: CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addCursorRect(bounds, cursor: .crosshair)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let end = dragCurrent else { return }
        isDragging = false

        let rect = normalizedRect(from: start, to: end)

        // Minimum size check (at least 10x10)
        if rect.width >= 10 && rect.height >= 10 {
            onRegionSelected?(rect)
        } else {
            // Too small — treat as a click, cancel
            needsDisplay = true
            dragStart = nil
            dragCurrent = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancelled?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent dark overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        // Clear cutout for selected region
        if isDragging, let start = dragStart, let current = dragCurrent {
            let selectionRect = normalizedRect(from: start, to: current)

            // Clear the selection area
            NSColor.clear.setFill()
            selectionRect.fill(using: .copy)

            // Draw border around selection
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let borderPath = NSBezierPath(rect: selectionRect)
            borderPath.lineWidth = 1.5
            borderPath.stroke()

            // Draw size label
            drawSizeLabel(for: selectionRect)
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        // Position label below the selection rect, or above if no room
        let labelPadding: CGFloat = 6
        var labelRect = CGRect(
            x: rect.midX - (textSize.width + labelPadding * 2) / 2,
            y: rect.minY - textSize.height - labelPadding * 2 - 4,
            width: textSize.width + labelPadding * 2,
            height: textSize.height + labelPadding * 2
        )
        if labelRect.minY < bounds.minY {
            labelRect.origin.y = rect.maxY + 4
        }

        // Background pill
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()

        // Text
        let textOrigin = NSPoint(x: labelRect.minX + labelPadding, y: labelRect.minY + labelPadding)
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func normalizedRect(from start: NSPoint, to end: NSPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may have warnings about ScreenCaptureKit availability — the min target is 14.4 which is fine)

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/ScreenCaptureService.swift
git commit -m "feat: add ScreenCaptureService with region overlay and SCScreenshotManager"
```

---

### Task 5: Register Screenshot Hotkey

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift`

**Step 1: Add screenshot shortcut name**

After the existing `commentOnSelection` shortcut name:
```swift
extension KeyboardShortcuts.Name {
    static let commentOnSelection = Self(
        "commentOnSelection",
        default: .init(.c, modifiers: [.command, .shift])
    )
    static let screenshotComment = Self(
        "screenshotComment",
        default: .init(.s, modifiers: [.command, .shift])
    )
}
```

**Step 2: Register the screenshot hotkey in `register()`**

```swift
public func register() {
    KeyboardShortcuts.onKeyDown(for: .commentOnSelection) { [weak self] in
        Task { @MainActor in
            self?.handleHotkey()
        }
    }
    KeyboardShortcuts.onKeyDown(for: .screenshotComment) { [weak self] in
        Task { @MainActor in
            self?.handleScreenshotHotkey()
        }
    }
    debugLog("GlobalHotkey: Registered (KeyboardShortcuts)")
}
```

**Step 3: Add `unregister` for screenshot shortcut**

```swift
public func unregister() {
    KeyboardShortcuts.disable(.commentOnSelection)
    KeyboardShortcuts.disable(.screenshotComment)
    debugLog("GlobalHotkey: Unregistered")
}
```

**Step 4: Add handler**

```swift
private func handleScreenshotHotkey() {
    debugLog("GlobalHotkey: screenshot hotkey fired")
    guard !SettingsManager.shared.isPaused else {
        debugLog("GlobalHotkey: paused, ignoring screenshot")
        return
    }

    ScreenCaptureService.shared.startCapture(
        onComplete: { imagePath, captureRect in
            CommentInputController.shared.showForScreenshot(imagePath: imagePath, captureRect: captureRect)
        },
        onCancel: {
            debugLog("GlobalHotkey: screenshot capture cancelled")
        }
    )
}
```

Note: `CommentInputController.showForScreenshot` will be added in Task 7.

**Step 5: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: May fail because `showForScreenshot` doesn't exist yet. That's OK — this will compile after Task 7.

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift
git commit -m "feat: register screenshot comment hotkey (Cmd+Shift+S)"
```

---

### Task 6: Add Screenshot Thumbnail Helper

A shared helper for loading and displaying screenshot thumbnails from relative image paths.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/ScreenshotThumbnailView.swift`

**Step 1: Create the thumbnail view**

```swift
import SwiftUI
import AppKit

/// Resolves a relative image path to an absolute URL under App Support/Remarc/
func resolveImagePath(_ relativePath: String) -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Remarc/\(relativePath)")
}

/// Loads an NSImage from a relative image path
func loadScreenshotImage(_ relativePath: String) -> NSImage? {
    let url = resolveImagePath(relativePath)
    return NSImage(contentsOf: url)
}

/// Displays a screenshot thumbnail with rounded corners
struct ScreenshotThumbnailView: View {
    let imagePath: String
    let maxWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = loadScreenshotImage(imagePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.12)
                                : Color.black.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
        } else {
            // Fallback if image file is missing
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 100, height: 60)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/ScreenshotThumbnailView.swift
git commit -m "feat: add ScreenshotThumbnailView helper"
```

---

### Task 7: Update CommentInputController for Screenshots

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`

**Step 1: Add screenshot state to CommentInputController**

Add published properties to `CommentInputController`:
```swift
@Published public var screenshotImagePath: String?
```

Add the `showForScreenshot` method:
```swift
public func showForScreenshot(imagePath: String, captureRect: CGRect) {
    SelectionTooltipWindowController.shared.dismiss()

    currentSelection = nil
    screenshotImagePath = imagePath
    textResetToken = UUID()

    show(near: captureRect)
}
```

Update `saveComment` to handle screenshot reference (replace lines 60-71 in the existing `saveComment`):
```swift
public func saveComment(text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        dismiss()
        return
    }

    let selection = currentSelection
    let source = selection?.source ?? (screenshotImagePath != nil ? "Screenshot" : "Quick Note")

    let reference: CommentReference
    if let imagePath = screenshotImagePath {
        reference = .screenshot(imagePath: imagePath)
    } else if let rawText = selection?.text {
        let trimmed = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        reference = trimmed.isEmpty ? .quickNote : .textSelection(text: trimmed)
    } else {
        reference = .quickNote
    }

    let comment = PersistenceManager.shared.createComment(
        reference: reference,
        commentText: text,
        source: source,
        appBundleID: selection?.appBundleID
    )

    if let comment = comment {
        LicenseManager.shared.recordComment()
        debugLog("CommentInputController: Comment saved (id=\(comment.id))")
    } else {
        debugLog("CommentInputController: Comment save FAILED — no active stack?")
    }

    dismissWithAnimation()
}
```

Update `dismiss()` to clear screenshot state:
```swift
public func dismiss() {
    panel?.orderOut(nil)
    removeClickOutsideMonitor()
    isVisible = false
    currentSelection = nil
    screenshotImagePath = nil
}
```

Also clear in `dismissWithAnimation()`:
```swift
private func dismissWithAnimation() {
    guard let panel = panel else {
        dismiss()
        return
    }
    removeClickOutsideMonitor()
    isVisible = false
    currentSelection = nil
    screenshotImagePath = nil
    // ... rest of animation code unchanged
}
```

**Step 2: Update CommentInputView to show screenshot thumbnail**

In `CommentInputView.swift`, update the reference section (lines 15-38) to handle screenshots:

```swift
// Source reference line
if let selection = controller.currentSelection {
    Text("\u{201C}\(selection.truncatedText)\u{201D}")
        .font(.system(size: 12.5))
        .italic()
        .foregroundStyle(Color.remarcAccent(for: colorScheme))
        .lineLimit(2)
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                .frame(width: 2)
        }
} else if let imagePath = controller.screenshotImagePath {
    ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 280)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                .frame(width: 2)
        }
} else {
    HStack(spacing: 4) {
        Image(systemName: "note.text")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        Text("Quick Note")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift
git commit -m "feat: support screenshot reference in comment input flow"
```

---

### Task 8: Create ScreenshotPreviewController

Full-size image preview panel that opens when clicking a screenshot thumbnail.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/ScreenshotPreviewController.swift`

**Step 1: Create the preview controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class ScreenshotPreviewController {
    static let shared = ScreenshotPreviewController()

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?

    private init() {}

    func show(imagePath: String, commentText: String?) {
        dismiss()

        guard let image = loadScreenshotImage(imagePath) else {
            debugLog("ScreenshotPreviewController: Failed to load image at \(imagePath)")
            return
        }

        let previewView = ScreenshotPreviewView(
            image: image,
            commentText: commentText,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: previewView)
        let fittingSize = hostingView.fittingSize

        // Constrain to 80% of screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let maxWidth = screen.frame.width * 0.8
        let maxHeight = screen.frame.height * 0.8
        let width = min(fittingSize.width, maxWidth)
        let height = min(fittingSize.height, maxHeight)

        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView = hostingView
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        installClickOutsideMonitor()
    }

    func dismiss() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
        panel = nil
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let panel = self.panel, panel.isVisible else { return }
                let mouseLocation = NSEvent.mouseLocation
                if !panel.frame.contains(mouseLocation) {
                    self.dismiss()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - Preview View

struct ScreenshotPreviewView: View {
    let image: NSImage
    let commentText: String?
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Image
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 800, maxHeight: 600)

            // Comment text if present
            if let text = commentText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onTapGesture { onDismiss() }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/ScreenshotPreviewController.swift
git commit -m "feat: add full-size screenshot preview panel"
```

---

### Task 9: Update CommentCardView for Screenshot Thumbnails

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

**Step 1: Update referenceView to handle screenshots**

Replace the `referenceView` computed property (lines 62-85):

```swift
@ViewBuilder
private var referenceView: some View {
    switch comment.reference {
    case .textSelection(let text):
        Text("\u{201C}\(text)\u{201D}")
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(Color.remarcAccent(for: colorScheme))
            .lineLimit(3)
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

    case .screenshot(let imagePath):
        ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 320)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ScreenshotPreviewController.shared.show(
                    imagePath: imagePath,
                    commentText: comment.commentText
                )
            }
            .contextMenu {
                Button("Copy Image") {
                    if let image = loadScreenshotImage(imagePath) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([image])
                        ToastManager.shared.show("Image copied")
                    }
                }
                Button("Save Image As...") {
                    saveScreenshotAs(imagePath: imagePath)
                }
            }

    case .quickNote:
        Label("Quick Note", systemImage: "note.text")
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.6))
    }
}
```

**Step 2: Add `saveScreenshotAs` helper to CommentCardView**

Add this private function to `CommentCardView`:

```swift
private func saveScreenshotAs(imagePath: String) {
    let sourceURL = resolveImagePath(imagePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = sourceURL.lastPathComponent
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true

    panel.begin { response in
        if response == .OK, let destURL = panel.url {
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                debugLog("ScreenshotCard: Saved to \(destURL.path)")
            } catch {
                debugLog("ScreenshotCard: Save failed — \(error)")
            }
        }
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift
git commit -m "feat: screenshot thumbnails in comment cards with preview and context menu"
```

---

### Task 10: Update CommentEditorView for Screenshots

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentEditorView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/FloatingEditorController.swift`

**Step 1: Add `screenshotImagePath` param to CommentEditorView**

Update `CommentEditorView` to accept an optional screenshot path:

```swift
struct CommentEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var commentText: String
    @FocusState private var isFocused: Bool
    @State private var isCloseHovered = false
    @State private var isSaveHovered = false

    let referenceText: String?
    let screenshotImagePath: String?
    let sourceName: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void
```

Update the reference section in the body (replace lines 19-44):

```swift
// Reference (read-only)
if let imagePath = screenshotImagePath {
    ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 400)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                .frame(width: 2)
        }
        .onTapGesture {
            ScreenshotPreviewController.shared.show(
                imagePath: imagePath,
                commentText: nil
            )
        }
} else if let ref = referenceText {
    VStack(alignment: .leading, spacing: 2) {
        Text("\u{201C}\(ref)\u{201D}")
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(Color.remarcAccent(for: colorScheme))
            .lineLimit(3)
        if let source = sourceName {
            Text(source)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
    .padding(.leading, 8)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
            .frame(width: 2)
    }
} else {
    Label("Quick Note", systemImage: "note.text")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
}
```

**Step 2: Update FloatingEditorController to pass screenshot path**

In `FloatingEditorController.swift`, update `showForEdit`:

```swift
public func showForEdit(comment: Comment) {
    show(
        referenceText: comment.reference.displayText,
        screenshotImagePath: comment.reference.imagePath,
        sourceName: comment.source,
        initialText: comment.commentText,
        onSave: { newText in
            PersistenceManager.shared.updateComment(comment.id, text: newText)
            ToastManager.shared.show("Comment updated")
            self.dismiss()
        }
    )
}
```

Update `showForQuickNote`:
```swift
public func showForQuickNote() {
    show(
        referenceText: nil,
        screenshotImagePath: nil,
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
            ToastManager.shared.show("Quick note saved")
            self.dismiss()
        }
    )
}
```

Update the private `show` method signature:
```swift
private func show(referenceText: String?, screenshotImagePath: String?, sourceName: String?, initialText: String, onSave: @escaping (String) -> Void) {
```

And update the `FloatingEditorWrapper` creation:
```swift
let wrapper = FloatingEditorWrapper(
    initialText: initialText,
    referenceText: referenceText,
    screenshotImagePath: screenshotImagePath,
    sourceName: sourceName,
    onSave: onSave,
    onCancel: { [weak self] in self?.dismiss() }
)
```

Update `FloatingEditorWrapper`:
```swift
struct FloatingEditorWrapper: View {
    @State private var text: String

    let referenceText: String?
    let screenshotImagePath: String?
    let sourceName: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialText: String, referenceText: String?, screenshotImagePath: String?, sourceName: String?, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initialText)
        self.referenceText = referenceText
        self.screenshotImagePath = screenshotImagePath
        self.sourceName = sourceName
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        CommentEditorView(
            commentText: $text,
            referenceText: referenceText,
            screenshotImagePath: screenshotImagePath,
            sourceName: sourceName,
            onSave: onSave,
            onCancel: onCancel
        )
        .frame(width: AppConstants.editorWidth)
        .onChange(of: text) { _, newValue in
            FloatingEditorController.shared.currentText = newValue
        }
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentEditorView.swift app/RemarcPackage/Sources/RemarcFeature/Views/FloatingEditorController.swift
git commit -m "feat: screenshot preview in comment editor"
```

---

### Task 11: Update Export for Screenshot References

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Update markdown export**

In `markdownForStack`, replace the comment export loop (lines 25-46):

```swift
for (index, comment) in comments.enumerated() {
    let number = index + 1
    lines.append("**\(number).**")

    switch comment.reference {
    case .textSelection(let text):
        let quotedLines = text.components(separatedBy: "\n").map { "> \($0)" }
        lines.append(contentsOf: quotedLines)
        lines.append("> Source: \(comment.source)")
    case .screenshot(let imagePath):
        lines.append("![\(comment.source)](\(imagePath))")
    case .quickNote:
        lines.append("> Quick Note")
    }

    lines.append("")
    lines.append(comment.commentText)
    lines.append("")

    if number < comments.count {
        lines.append("---")
        lines.append("")
    }
}
```

**Step 2: Update JSON export**

In `jsonForStack`, update `ExportComment` struct:

```swift
struct ExportComment: Encodable {
    let number: Int
    let selectedText: String?
    let imagePath: String?
    let comment: String
    let source: String
    let timestamp: String
}
```

And the mapping:
```swift
let exportComments = comments.enumerated().map { index, comment in
    ExportComment(
        number: index + 1,
        selectedText: comment.selectedText,
        imagePath: comment.reference.imagePath,
        comment: comment.commentText,
        source: comment.source,
        timestamp: formatter.string(from: comment.createdAt)
    )
}
```

**Step 3: Update single comment export**

In `markdownForComment`:
```swift
public func markdownForComment(_ comment: Comment) -> String {
    var lines: [String] = []

    switch comment.reference {
    case .textSelection(let text):
        let quotedLines = text.components(separatedBy: "\n").map { "> \($0)" }
        lines.append(contentsOf: quotedLines)
        lines.append("> Source: \(comment.source)")
        lines.append("")
    case .screenshot(let imagePath):
        lines.append("![\(comment.source)](\(imagePath))")
        lines.append("")
    case .quickNote:
        break
    }

    lines.append(comment.commentText)
    return lines.joined(separator: "\n")
}
```

**Step 4: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift
git commit -m "feat: handle screenshot references in markdown and JSON export"
```

---

### Task 12: Delete Image File on Permanent Comment Deletion

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Update `permanentlyDeleteComment`**

Replace the existing `permanentlyDeleteComment` method:

```swift
public func permanentlyDeleteComment(_ id: UUID) {
    // Delete associated image file if this is a screenshot comment
    if let comment = appState.comments.first(where: { $0.id == id }),
       let imagePath = comment.reference.imagePath {
        let url = resolveImagePath(imagePath)
        try? FileManager.default.removeItem(at: url)
        debugLog("PersistenceManager: Deleted image file \(imagePath)")
    }

    appState.comments.removeAll { $0.id == id }
    scheduleSave()
}
```

Note: `resolveImagePath` is defined in `ScreenshotThumbnailView.swift` as a free function.

Also update `permanentlyDeleteStack` to clean up images:

```swift
public func permanentlyDeleteStack(_ id: UUID) {
    // Delete image files for any screenshot comments in this stack
    for comment in appState.comments where comment.stackID == id {
        if let imagePath = comment.reference.imagePath {
            let url = resolveImagePath(imagePath)
            try? FileManager.default.removeItem(at: url)
        }
    }

    appState.stacks.removeAll { $0.id == id }
    appState.comments.removeAll { $0.stackID == id }
    scheduleSave()
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift
git commit -m "feat: delete screenshot image files on permanent comment deletion"
```

---

### Task 13: Add Screenshot Button to Popover Header + Preferences

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Add screenshot button to popover header**

In `PopoverContentView.swift`, in the `normalHeader` view (after the quick note button and before the gear button):

```swift
headerButton(icon: "camera.viewfinder") {
    MenuBarPopoverController.shared.dismiss()
    ScreenCaptureService.shared.startCapture(
        onComplete: { imagePath, captureRect in
            CommentInputController.shared.showForScreenshot(imagePath: imagePath, captureRect: captureRect)
        },
        onCancel: {
            debugLog("PopoverHeader: screenshot capture cancelled")
        }
    )
}
```

The full normalHeader becomes:
```swift
private var normalHeader: some View {
    HStack {
        HStack(spacing: 0) {
            let count = persistence.activeComments.count
            Text("\(count) ")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.remarcAccent(for: colorScheme))
            Text(count == 1 ? "Comment" : "Comments")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
        }

        Spacer()

        if hasComments {
            headerButton(icon: "magnifyingglass") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSearching = true
                }
            }

            headerButton(icon: sortNewestFirst ? "arrow.down" : "arrow.up") {
                sortNewestFirst.toggle()
            }
        }

        headerButton(icon: "note.text.badge.plus") {
            FloatingEditorController.shared.showForQuickNote()
        }

        headerButton(icon: "camera.viewfinder") {
            MenuBarPopoverController.shared.dismiss()
            ScreenCaptureService.shared.startCapture(
                onComplete: { imagePath, captureRect in
                    CommentInputController.shared.showForScreenshot(imagePath: imagePath, captureRect: captureRect)
                },
                onCancel: {
                    debugLog("PopoverHeader: screenshot capture cancelled")
                }
            )
        }

        headerButton(icon: "gearshape") {
            PreferencesWindowController.shared.show()
        }

        if popoverController.isDetached {
            headerButton(icon: detachedController.isPinned ? "pin.fill" : "pin") {
                detachedController.togglePin()
            }
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
}
```

**Step 2: Add screenshot shortcut recorder and clipboard toggle to Preferences**

In `PreferencesWindowController.swift`, update the `generalTab`:

```swift
private var generalTab: some View {
    Form {
        Toggle("Launch at Login", isOn: Binding(
            get: { settings.launchAtLogin },
            set: { settings.launchAtLogin = $0 }
        ))
        Toggle("Pause selection detection", isOn: $settings.isPaused)
        KeyboardShortcuts.Recorder("Comment shortcut:", name: .commentOnSelection)
        KeyboardShortcuts.Recorder("Screenshot shortcut:", name: .screenshotComment)
        Picker("Detection mode", selection: $settings.selectionDetectionMode) {
            ForEach(SettingsManager.SelectionDetectionMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        Toggle("Clean up terminal whitespace", isOn: $settings.normalizeWhitespace)
        Toggle("Copy screenshot to clipboard on capture", isOn: $settings.copyScreenshotToClipboard)
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add screenshot button to popover header and preferences"
```

---

### Task 14: Full Integration Build and Launch

**Step 1: Clean build**

```bash
cd app && xcodebuild clean -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet
```

**Step 2: Build**

```bash
xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

**Step 3: Kill existing and launch**

```bash
pkill -x Remarc || true
```

Extract DerivedData path from build output and launch:
```bash
open <derived-data-path>/Build/Products/Debug/Remarc.app
```

**Step 4: Manual verification checklist**

1. Open popover — verify camera icon in header
2. Click camera icon — verify overlay appears with crosshair cursor
3. Drag to select region — verify rubber-band selection with size label
4. Release — verify comment input panel appears with screenshot thumbnail
5. Type comment and save — verify comment card shows thumbnail
6. Click thumbnail in card — verify full-size preview opens
7. Right-click thumbnail — verify "Copy Image" and "Save Image As..." in context menu
8. Edit comment — verify screenshot preview in editor
9. Test Cmd+Shift+S hotkey — verify same capture flow
10. Settings > General — verify screenshot shortcut recorder and clipboard toggle
11. Export as markdown — verify `![screenshot](images/uuid.png)` format
12. Delete comment — verify image file is removed from disk
