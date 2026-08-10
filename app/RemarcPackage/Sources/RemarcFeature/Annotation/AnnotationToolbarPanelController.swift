import AppKit
import SwiftUI
import Combine

/// The toolbar panel's own Escape handling.
///
/// `KeyablePanel` in `CommentInputWindowController` is shared with the voice path
/// and branches on `autoSaveCountdownActive`; reusing it here would either steal
/// that branch or need a third condition inside a type that already has two.
private final class KeyableAnnotationPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Floating toolbar for the capture-time annotation surface.
///
/// Nonactivating and keyable, at `.screenSaver + 2`. It is ordered out before the
/// fly panel is created, so the two never contend for that slot.
@MainActor
final class AnnotationToolbarPanelController {

    private var panel: KeyableAnnotationPanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var session: AnnotationSession?

    var onCancel: (() -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onDone: (() -> Void)?
    var onRequestDiscard: (() -> Void)?
    var onConfirmDiscard: (() -> Void)?
    var onCancelDiscard: (() -> Void)?

    /// Fixed worst-case metrics, deliberately not measurements of the live
    /// toolbar. Measuring would be circular: the stepper only appears once `zMax`
    /// is known, and `zMax` depends on an allowance computed from this reserve, so
    /// adding the stepper could invalidate the allowance that enabled it.
    static let worstCaseWidth: CGFloat = 620
    /// The toolbar docks BELOW the stage, so what the stage has to give up is
    /// vertical: its height plus the 10pt gap plus a little slack.
    static let reserve: CGFloat = height + 10 + 8
    static let height: CGFloat = 42

    init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: AnnotationSession,
                     anchoredBelow rect: CGRect,
                     on screen: NSScreen,
                     zoomState: AnnotationToolbarView.ZoomState?,
                     showsDiscardControls: Bool) {
        self.session = session

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let view = AnnotationToolbarView(
            session: session,
            zoomState: zoomState,
            showsDiscardControls: showsDiscardControls,
            onZoomStep: { [weak self] in self?.onZoomStep?($0) },
            onUndo: { session.undo() },
            onRedo: { session.redo() },
            onDone: { [weak self] in self?.onDone?() },
            onRequestDiscard: { [weak self] in self?.onRequestDiscard?() },
            onConfirmDiscard: { [weak self] in self?.onConfirmDiscard?() },
            onCancelDiscard: { [weak self] in self?.onCancelDiscard?() }
        )

        if let hosting {
            hosting.rootView = AnyView(view)
        } else {
            let hosting = NSHostingView(rootView: AnyView(view))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            (panel.contentView as? NSVisualEffectView)?.addSubview(hosting)
            if let container = panel.contentView {
                NSLayoutConstraint.activate([
                    hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    hosting.topAnchor.constraint(equalTo: container.topAnchor),
                    hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
            }
            self.hosting = hosting
        }

        // Lay the row out BEFORE measuring. `fittingSize` read straight after
        // swapping `rootView` returns the previous layout's size, so the panel got
        // a stale width and the centring was visibly off - measured about 74pt to
        // the right of the stage's midpoint on device.
        hosting?.layoutSubtreeIfNeeded()
        let fitting = hosting?.fittingSize ?? NSSize(width: 420, height: Self.height)
        let width = min(max(fitting.width.rounded(.up), 240), Self.worstCaseWidth)
        let height = max(fitting.height.rounded(.up), Self.height)

        // Docked under the stage and centred on it. At 1x the stage has no proven
        // room, so this falls back rather than assuming a fit.
        var origin = CGPoint(x: (rect.midX - width / 2).rounded(),
                             y: rect.minY - height - 10)
        let visible = screen.visibleFrame
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 10 }
        if origin.y + height > visible.maxY - 8 { origin.y = visible.midY - height / 2 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - width - 8))

        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)),
                       display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> KeyableAnnotationPanel {
        let panel = KeyableAnnotationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        // One raw level above the comment panel, which sits at .screenSaver + 1.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.onCancel?() }

        // AppKit VEV owns the material. DESIGN.md forbids a SwiftUI material over
        // it, so the SwiftUI content stays transparent.
        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 10
        vev.layer?.masksToBounds = true
        panel.contentView = vev
        return panel
    }

    func orderOut() {
        panel?.orderOut(nil)
    }

    func teardown() {
        hosting?.removeFromSuperview()
        hosting = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        session = nil
    }
}
