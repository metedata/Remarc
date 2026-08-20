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
    /// The last selection cleared, kept briefly for triggers that arrive after a
    /// deselecting click. Read only via `readRecentSelection`; the hotkey path
    /// deliberately does not consult it.
    private var recentStash = RecentSelectionStash()

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
        recentStash.clear()
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
        // Fallback when no selection was captured: used directly by the hotkey,
        // and as the last resort of readRecentSelection when neither the live
        // selection nor the stash has anything. Not specific to hotkeyOnly mode -
        // that mode leaves the monitor running, so currentSelection is populated
        // the same as in auto-detect.
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
            } else if event.clickCount < 2, let dismissed = currentSelection {
                // Simple click (not double-click, not drag) = deselection.
                // Stash it: a click on PopClip's bar lands here, and the
                // remarc:// trigger that follows still needs the selection.
                recentStash.store(dismissed, at: CFAbsoluteTimeGetCurrent())
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
            // A failed read still invalidates the stash: the user has moved on
            // to a different (unreadable) selection, so a stale stash from the
            // previous one must not be handed to a trigger that arrives next.
            recentStash.clear()
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
