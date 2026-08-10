import AppKit

// MARK: - Click-Outside Monitor

/// Manages a global NSEvent monitor that calls a dismiss closure when the user clicks outside a panel.
/// Replaces the duplicated install/remove pattern in MenuBarPopoverController, FloatingEditorController,
/// ScreenshotPreviewController, and CommentInputController.
final class ClickOutsideMonitor {
    private var monitor: Any?

    /// Install a global monitor. Any existing monitor is removed first.
    /// - Parameters:
    ///   - panel: The panel to watch. Clicks inside its frame are ignored.
    ///   - shouldDismiss: Called on MainActor before dismissing. Return `false` to suppress.
    ///   - dismiss: Called on MainActor when the user clicks outside.
    func install(for panel: NSPanel, shouldDismiss: @escaping @MainActor () -> Bool = { true }, dismiss: @escaping @MainActor () -> Void) {
        remove()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                guard panel.isVisible else { return }
                guard shouldDismiss() else { return }
                let mouseLocation = NSEvent.mouseLocation
                if !panel.frame.contains(mouseLocation) {
                    dismiss()
                }
            }
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - NSView Scroller Suppression

extension NSView {
    /// Recursively walks the view hierarchy and disables scrollers on every NSScrollView found.
    /// SwiftUI `.scrollIndicators(.hidden)` is unreliable on macOS — this walks the AppKit hierarchy.
    func disableScrollers() {
        if let scrollView = self as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            scrollView.tile()
            scrollView.needsLayout = true
        }
        for subview in subviews {
            subview.disableScrollers()
        }
        layoutSubtreeIfNeeded()
    }
}

// MARK: - NSScreen Extensions

extension NSScreen {
    /// Returns the screen containing the given point, or `nil` if no screen matches.
    static func screen(containing point: NSPoint) -> NSScreen? {
        screens.first(where: { $0.frame.contains(point) })
    }

    /// Best screen for a window: the window's own screen, then `.main`, then first available.
    static func bestScreen(for window: NSWindow? = nil) -> NSScreen {
        window?.screen ?? main ?? screens.first!
    }
}

// MARK: - NSWindow Extensions

extension NSWindow {
    /// Centers the window on its own screen's visible frame (falls back to main screen).
    func centerOnScreen() {
        let screen = NSScreen.bestScreen(for: self)
        let frame = screen.visibleFrame
        let x = frame.midX - self.frame.width / 2
        let y = frame.midY - self.frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Fades out, then orders out and resets alphaValue. Calls `completion` on MainActor.
    func fadeOut(duration: TimeInterval = 0.25, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
                self?.alphaValue = 1
                completion?()
            }
        })
    }
}
