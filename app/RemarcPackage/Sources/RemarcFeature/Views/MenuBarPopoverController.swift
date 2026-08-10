import AppKit
import SwiftUI
import Combine

private class KeyablePopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            MenuBarPopoverController.shared.dismiss()
        }
    }
}

@MainActor
public final class MenuBarPopoverController: NSObject, ObservableObject {
    public static let shared = MenuBarPopoverController()

    @Published public var isVisible: Bool = false
    @Published public var isDetached: Bool = false
    /// When true, prevents click-outside dismissal (e.g. during Crit Mode recording/processing)
    public var preventDismiss: Bool = false
    /// Set to true by GlobalHotkey to request crit mode start. PopoverContentView observes and resets.
    @Published public var requestCritMode: Bool = false

    /// Makes the panel the key window (needed for TextField caret in non-activating panels).
    public func makeKey() {
        panel?.makeKey()
    }

    /// Set by AppController so we can position below the status item.
    public var statusItemButton: NSStatusBarButton?

    private var panel: NSPanel?
    private var popoverHostingView: NSHostingView<PopoverContentView>?
    private let clickOutsideMonitor = ClickOutsideMonitor()
    private var commentCountCancellable: AnyCancellable?
    private var lastArrowCenterX: CGFloat = 0
    /// High-water mark: the panel never shrinks below this height while visible.
    private var sessionHighWaterMark: CGFloat = 0

    private override init() {
        super.init()
        observeCommentChanges()
    }

    // MARK: - Public API

    public func toggle() {
        if isDetached {
            DetachedWindowController.shared.bringToFront()
            return
        }
        if isVisible {
            guard !preventDismiss else { return }
            dismiss()
        } else {
            show()
        }
    }

    public func show() {
        if panel == nil {
            createPanel()
        }
        positionBelowStatusItem()

        guard let panel = panel else { return }

        // Animate in: start slightly above and transparent, slide down + fade in
        let finalFrame = panel.frame
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        isVisible = true
        clickOutsideMonitor.install(for: panel, shouldDismiss: { [weak self] in !(self?.preventDismiss ?? false) }, dismiss: { [weak self] in self?.dismiss() })
        // SwiftUI .scrollIndicators(.hidden) is unreliable on macOS — the underlying
        // NSScrollView still shows its scroller. Walk the AppKit hierarchy to disable it.
        DispatchQueue.main.async { [weak self] in
            if let contentView = self?.panel?.contentView {
                contentView.disableScrollers()
            }
        }
        debugLog("MenuBarPopoverController: shown")
    }

    public func dismiss() {
        guard let panel = panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true)
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1  // Reset for next show
            self?.clickOutsideMonitor.remove()
            self?.isVisible = false
            self?.sessionHighWaterMark = 0  // Reset for next session
            debugLog("MenuBarPopoverController: dismissed")
        }
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let panel = KeyablePopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.popoverWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true  // shadow follows VEV mask shape
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.identifier = NSUserInterfaceItemIdentifier("remarc.popover")
        // Do NOT set panel.appearance — causes vibrancy mismatch on material backgrounds

        // NSVisualEffectView as contentView with maskImage.
        // This communicates the rounded shape to the window server so backdrop blur
        // is composited in the correct shape — eliminating corner artifacts.
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active  // prevents dimming on focus loss
        panel.contentView = visualEffectView

        // NSHostingView as subview of VEV — NOT as panel.contentView.
        // The SwiftUI content must have NO .background(.regularMaterial) since VEV provides it.
        // Store a direct reference for sizing (VEV has internal subviews, so subview lookup is unreliable).
        // topInset pushes the content below the arrow strip while the SwiftUI background
        // gradient fills the full panel — otherwise the arrow renders bare VEV material
        // and visibly differs in color from the gradient-tinted body.
        let arrowH = AppConstants.popoverArrowHeight
        let contentView = PopoverContentView(topInset: arrowH)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // Measure ideal size first, then size the panel to fit
        // (fittingSize already includes the arrow strip via topInset)
        let idealSize = hostingView.fittingSize
        panel.setContentSize(NSSize(width: AppConstants.popoverWidth, height: idealSize.height))

        // Pin hosting view to VEV edges with Auto Layout — full panel, including the arrow strip.
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        // Apply a placeholder mask with centered arrow — real mask set in positionBelowStatusItem()
        let placeholderSize = NSSize(width: AppConstants.popoverWidth, height: idealSize.height)
        visualEffectView.maskImage = Self.maskImage(
            size: placeholderSize,
            cornerRadius: AppConstants.panelCornerRadius,
            arrowWidth: AppConstants.popoverArrowWidth,
            arrowHeight: arrowH,
            arrowCenterX: placeholderSize.width / 2
        )

        self.popoverHostingView = hostingView
        self.panel = panel
    }

    /// Creates a full-size mask image with a rounded-rect body and an upward-pointing arrow.
    /// Rendered at exact panel size (no stretchable caps) so the arrow position is pixel-accurate.
    /// The window server uses this to composite backdrop blur in the correct shape.
    private static func maskImage(
        size: NSSize,
        cornerRadius: CGFloat,
        arrowWidth: CGFloat,
        arrowHeight: CGFloat,
        arrowCenterX: CGFloat
    ) -> NSImage {
        // flipped: true so y=0 is at top (arrow tip at top, body below)
        let img = NSImage(size: size, flipped: true) { rect in
            let bodyTop = arrowHeight

            let path = NSBezierPath()
            let cr = cornerRadius
            let halfArrow = arrowWidth / 2
            let tipRadius: CGFloat = 2  // slight rounding at the arrow tip

            // Start at top-left corner of body (after corner arc)
            path.move(to: NSPoint(x: 0, y: bodyTop + cr))

            // Top-left corner
            path.appendArc(
                from: NSPoint(x: 0, y: bodyTop),
                to: NSPoint(x: cr, y: bodyTop),
                radius: cr
            )

            // Top edge to arrow left base
            path.line(to: NSPoint(x: arrowCenterX - halfArrow, y: bodyTop))

            // Arrow: left side up to tip, then right side down — cubic curves for smooth shape
            let tipY: CGFloat = tipRadius  // tip nearly at top, offset by tip radius
            path.curve(
                to: NSPoint(x: arrowCenterX, y: tipY),
                controlPoint1: NSPoint(x: arrowCenterX - halfArrow * 0.3, y: bodyTop),
                controlPoint2: NSPoint(x: arrowCenterX - tipRadius, y: tipY)
            )
            path.curve(
                to: NSPoint(x: arrowCenterX + halfArrow, y: bodyTop),
                controlPoint1: NSPoint(x: arrowCenterX + tipRadius, y: tipY),
                controlPoint2: NSPoint(x: arrowCenterX + halfArrow * 0.3, y: bodyTop)
            )

            // Top edge from arrow right base to top-right corner
            path.line(to: NSPoint(x: rect.width - cr, y: bodyTop))

            // Top-right corner
            path.appendArc(
                from: NSPoint(x: rect.width, y: bodyTop),
                to: NSPoint(x: rect.width, y: bodyTop + cr),
                radius: cr
            )

            // Right edge
            path.line(to: NSPoint(x: rect.width, y: rect.height - cr))

            // Bottom-right corner
            path.appendArc(
                from: NSPoint(x: rect.width, y: rect.height),
                to: NSPoint(x: rect.width - cr, y: rect.height),
                radius: cr
            )

            // Bottom edge
            path.line(to: NSPoint(x: cr, y: rect.height))

            // Bottom-left corner
            path.appendArc(
                from: NSPoint(x: 0, y: rect.height),
                to: NSPoint(x: 0, y: rect.height - cr),
                radius: cr
            )

            // Left edge back to start
            path.close()

            NSColor.black.set()
            path.fill()
            return true
        }
        // No capInsets or stretch — rendered at exact panel size
        return img
    }

    // MARK: - Positioning

    private func positionBelowStatusItem() {
        guard let panel = panel else { return }

        // Get status item button position in screen coordinates
        guard let button = statusItemButton,
              let buttonWindow = button.window else {
            // Fallback: center horizontally on screen near menu bar
            if let screen = NSScreen.main {
                let screenFrame = screen.frame
                let visibleFrame = screen.visibleFrame
                let x = screenFrame.midX - panel.frame.width / 2
                let y = visibleFrame.maxY - panel.frame.height - AppConstants.popoverGap
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                applyMask(arrowCenterX: panel.frame.width / 2)
            }
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)

        // Compute max height
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let maxHeight = screen.visibleFrame.height * AppConstants.popoverMaxHeightRatio

        // Update panel content size to respect max height (fittingSize includes the arrow strip).
        // Uses stored popoverHostingView reference — NOT subview lookup,
        // because NSVisualEffectView has internal subviews that make .first unreliable.
        if let hostingView = popoverHostingView {
            hostingView.invalidateIntrinsicContentSize()
            let fittingSize = hostingView.fittingSize
            let minPanelHeight = AppConstants.popoverMinHeight
            let constrainedHeight = max(minPanelHeight, min(fittingSize.height, maxHeight))
            panel.setContentSize(NSSize(width: AppConstants.popoverWidth, height: constrainedHeight))
            sessionHighWaterMark = constrainedHeight
            panel.invalidateShadow()
        }

        // Center below status item button
        var x = buttonFrameOnScreen.midX - panel.frame.width / 2
        let y = buttonFrameOnScreen.minY - panel.frame.height - AppConstants.popoverGap

        // Clamp to screen edges
        let screenFrame = screen.visibleFrame
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panel.frame.width - 8))

        panel.setFrameOrigin(NSPoint(x: x, y: max(y, screenFrame.minY + 8)))

        // Compute arrow X relative to panel, pointing at the status item center
        let arrowCenterX = buttonFrameOnScreen.midX - panel.frame.origin.x
        applyMask(arrowCenterX: arrowCenterX)
    }

    /// Applies the arrow mask to the VEV at the given arrow X position, clamped to stay within the body.
    private func applyMask(arrowCenterX: CGFloat) {
        guard let panel = panel,
              let vev = panel.contentView as? NSVisualEffectView else { return }

        let cr = AppConstants.panelCornerRadius
        let arrowW = AppConstants.popoverArrowWidth
        let arrowH = AppConstants.popoverArrowHeight
        let panelSize = panel.frame.size

        // Clamp arrow to stay within body (at least cornerRadius + halfArrow + 2 from edges)
        let minX = cr + arrowW / 2 + 2
        let maxX = panelSize.width - cr - arrowW / 2 - 2
        let clampedX = max(minX, min(arrowCenterX, maxX))

        lastArrowCenterX = clampedX

        vev.maskImage = Self.maskImage(
            size: panelSize,
            cornerRadius: cr,
            arrowWidth: arrowW,
            arrowHeight: arrowH,
            arrowCenterX: clampedX
        )
        panel.invalidateShadow()
    }

    // MARK: - Dynamic Resize on Comment Changes

    private func observeCommentChanges() {
        commentCountCancellable = PersistenceManager.shared.$appState
            .map { state -> Int in
                guard let sessionID = state.activeSessionID else { return 0 }
                return state.comments.filter { $0.sessionID == sessionID && !$0.isDeleted }.count
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resizeIfVisible()
            }
    }

    /// Triggers a resize after SwiftUI layout settles (next runloop tick).
    /// The panel only grows — the high-water mark prevents shrinking while visible.
    public func resizeAfterLayoutSettles() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.resizeIfVisible()
        }
    }

    private func resizeIfVisible() {
        guard isVisible, let panel = panel, let hostingView = popoverHostingView else { return }

        hostingView.invalidateIntrinsicContentSize()
        let fittingSize = hostingView.fittingSize

        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let maxHeight = screen.visibleFrame.height * AppConstants.popoverMaxHeightRatio
        let minPanelHeight = AppConstants.popoverMinHeight
        let floorHeight = max(minPanelHeight, sessionHighWaterMark)
        let newHeight = min(max(floorHeight, min(fittingSize.height, maxHeight)), maxHeight)

        // Update high-water mark if we grew
        if newHeight > sessionHighWaterMark {
            sessionHighWaterMark = newHeight
        }

        let oldFrame = panel.frame
        guard abs(newHeight - oldFrame.height) > 1 else { return }

        // Compute target frame preserving maxY (top edge).
        let targetFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.maxY - newHeight,
            width: AppConstants.popoverWidth,
            height: newHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.applyMask(arrowCenterX: self?.lastArrowCenterX ?? targetFrame.width / 2)
        }
    }
}
