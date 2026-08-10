import AppKit
import Combine
import ApplicationServices

/// Detects text selection in any app using mouse event monitoring (like PopClip/Xpop).
///
/// Architecture:
/// 1. Monitors global mouse events (drag+release, double-click) to detect WHEN selection happens
/// 2. Delegates to TextReader for the actual text retrieval (AX → WebKit → clipboard)
/// 3. Publishes `currentSelection` for the tooltip and other subscribers
@MainActor
public final class SelectionMonitor: ObservableObject {
    public static let shared = SelectionMonitor()

    @Published public private(set) var currentSelection: TextSelection?

    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var dragEventCount: Int = 0
    private var isMouseDown: Bool = false
    private var mouseDownTime: CFAbsoluteTime = 0
    private var readWorkItem: DispatchWorkItem?
    private var lastReadText: String = ""
    private var lastReadTime: CFAbsoluteTime = 0
    private let readCooldown: CFAbsoluteTime = 0.3
    /// Mouse position captured at the end of the selection gesture (mouseUp/double-click)
    private var gestureEndMouseLocation: NSPoint?
    /// Pasteboard change count captured at gesture start for passive copy-on-select fallbacks.
    private var gestureStartPasteboardChangeCount: Int?

    private init() {}

    // MARK: - Public API

    public func startMonitoring() {
        guard globalMonitor == nil else { return }
        debugLog("SelectionMonitor: Starting event-driven monitoring")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
        ]) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // Ignore Cmd+key shortcuts (Cmd+C, Cmd+A, etc.) — those aren't typing
            guard !event.modifierFlags.contains(.command) else { return }

            // Cancel any pending text read (user started typing before read fired)
            self.readWorkItem?.cancel()

            // If a selection was captured very recently (< 0.5s), it was likely a
            // transient double-click word highlight — clear it so tooltip dismisses.
            if self.currentSelection != nil,
               CFAbsoluteTimeGetCurrent() - self.lastReadTime < 0.5 {
                self.currentSelection = nil
                self.lastReadText = ""
                debugLog("SelectionMonitor: Keystroke dismissed recent selection")
            }
        }
    }

    public func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        readWorkItem?.cancel()
        readWorkItem = nil
        currentSelection = nil
        lastReadText = ""
        gestureStartPasteboardChangeCount = nil
        debugLog("SelectionMonitor: Stopped")
    }

    /// One-shot read for hotkey trigger. Prefers the already-captured selection
    /// (from mouse-event detection), then falls back to a fresh AX/clipboard read.
    public func readCurrentSelection() -> TextSelection? {
        // Use the selection already captured by mouse-event monitoring if available.
        // This is more reliable than a fresh read during a Carbon hotkey callback,
        // where simulated Cmd+C can fail due to physical modifier keys still held.
        if let existing = currentSelection {
            debugLog("readCurrentSelection: using existing selection")
            return existing
        }

        debugLog("readCurrentSelection: no stored selection, trying fresh read")
        // Fresh read fallback (hotkeyOnly mode or selection not auto-detected)
        if let result = TextReader.shared.readSelectionViaClipboard() {
            let mouseLocation = NSEvent.mouseLocation
            let bounds = TextReader.shared.readSelection()?.bounds
            let rect = bounds ?? CGRect(x: mouseLocation.x - 50, y: mouseLocation.y, width: 100, height: 20)
            return TextSelection(
                text: result.text,
                source: result.source,
                appBundleID: result.bundleID,
                screenRect: rect
            )
        }
        return nil
    }

    // MARK: - Mouse Event Handling

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isMouseDown = true
            dragEventCount = 0
            mouseDownTime = CFAbsoluteTimeGetCurrent()
            gestureStartPasteboardChangeCount = NSPasteboard.general.changeCount

            // Single click dismisses current selection
            readWorkItem?.cancel()

            if event.clickCount >= 2 {
                debugLog("SelectionMonitor: Multi-click detected (clickCount=\(event.clickCount))")
                gestureEndMouseLocation = NSEvent.mouseLocation
                if event.clickCount >= 3 {
                    lastReadTime = 0 // Reset cooldown so triple-click read isn't blocked by a prior double-click read
                }
                scheduleTextRead(delay: 0.15)
            }

        case .leftMouseDragged:
            if isMouseDown {
                dragEventCount += 1
            }

        case .leftMouseUp:
            isMouseDown = false

            // Drag selection: mouseDown → N drags → mouseUp
            if dragEventCount >= 3 {
                debugLog("SelectionMonitor: Drag selection detected (dragCount=\(dragEventCount))")
                gestureEndMouseLocation = NSEvent.mouseLocation
                scheduleTextRead(delay: 0.1) // 100ms for app to finalize selection
            } else if event.clickCount < 2 && currentSelection != nil {
                // Simple click (not double-click, not drag) = deselection
                // Only clear if we had a selection — don't AX query on every click
                currentSelection = nil
                lastReadText = ""
            }
            dragEventCount = 0

        default:
            break
        }
    }

    // MARK: - Text Reading

    private func scheduleTextRead(delay: TimeInterval) {
        readWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performTextRead()
        }
        readWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performTextRead() {
        // Rate limit
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReadTime >= readCooldown else { return }
        lastReadTime = now

        // Use gesture-end mouse position (more accurate than current position after delay)
        let fallbackMouse = gestureEndMouseLocation ?? NSEvent.mouseLocation

        // Try AX first, then passive copy-on-select for terminal renderers,
        // then simulated Cmd+C only for apps known to need it. Blindly simulating
        // Cmd+C in arbitrary apps interferes with non-text drag gestures (e.g.
        // CleanShot region selection interprets the synthetic Cmd+C as "capture").
        var result = TextReader.shared.readSelection()
        if result == nil && TextReader.shared.frontmostAppMayPublishSelectionToClipboard() {
            debugLog("SelectionMonitor: AX failed in terminal-style app, checking passive pasteboard selection")
            if let clipResult = TextReader.shared.readSelectionFromPasteboardIfChanged(
                since: gestureStartPasteboardChangeCount
            ) {
                result = (text: clipResult.text, source: clipResult.source, bundleID: clipResult.bundleID,
                          bounds: CGRect(x: fallbackMouse.x - 50, y: fallbackMouse.y, width: 100, height: 5))
            }
        }
        if result == nil && TextReader.shared.frontmostAppNeedsClipboardFallback() {
            debugLog("SelectionMonitor: AX failed in GPU-rendered app, trying clipboard fallback")
            if let clipResult = TextReader.shared.readSelectionViaClipboard() {
                result = (text: clipResult.text, source: clipResult.source, bundleID: clipResult.bundleID,
                          bounds: CGRect(x: fallbackMouse.x - 50, y: fallbackMouse.y, width: 100, height: 5))
            }
        }

        guard let result = result else {
            debugLog("SelectionMonitor: No text found after gesture")
            if currentSelection != nil {
                currentSelection = nil
            }
            return
        }

        // Use mouse position as fallback for bounds
        let screenRect: CGRect
        if let bounds = result.bounds, bounds.width > 0, bounds.height > 0 {
            screenRect = bounds
        } else {
            // Place thin rect at the cursor so tooltip appears just above it
            screenRect = CGRect(x: fallbackMouse.x - 50, y: fallbackMouse.y, width: 100, height: 5)
        }

        let selection = TextSelection(
            text: result.text,
            source: result.source,
            appBundleID: result.bundleID,
            screenRect: screenRect
        )

        // Only update if text actually changed
        if result.text != lastReadText {
            lastReadText = result.text
            currentSelection = selection
            debugLog("SelectionMonitor: Selection detected: \"\(result.text.prefix(40))...\" in \(result.source), bounds=\(screenRect)")
        }
    }

}
