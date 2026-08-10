import AppKit
import SwiftUI

@MainActor
public final class DetachedWindowController: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = DetachedWindowController()

    @Published public var isVisible: Bool = false
    @Published public var isPinned: Bool = false

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    public func show() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
        MenuBarPopoverController.shared.isDetached = true
        // SwiftUI .scrollIndicators(.hidden) is unreliable — walk AppKit hierarchy
        DispatchQueue.main.async { [weak self] in
            if let contentView = self?.window?.contentView {
                contentView.disableScrollers()
            }
        }
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
                NSApp.activate(ignoringOtherApps: true)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.popoverWidth, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Prevent AppKit's legacy release-on-close (crashes under ARC with dangling pointers)
        window.isReleasedWhenClosed = false
        window.title = "Remarc Comments"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 300, height: 200)
        window.center()
        window.delegate = self

        // NSVisualEffectView as contentView — matches the popover's translucent material
        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        window.contentView = vev

        // NSHostingView as subview of VEV — NO SwiftUI material backgrounds
        let hostingView = NSHostingView(rootView: DetachedWindowContentView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        vev.addSubview(hostingView)

        // Pin to VEV edges on all sides — the gradient background extends behind
        // the titlebar. SwiftUI safe area keeps interactive content below traffic lights.
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: vev.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: vev.bottomAnchor),
        ])

        self.window = window
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        isVisible = false
        isPinned = false
        window = nil
        MenuBarPopoverController.shared.isDetached = false
    }
}

// MARK: - Content View

struct DetachedWindowContentView: View {
    var body: some View {
        PopoverContentView(fillWidth: true)
    }
}

