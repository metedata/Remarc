import AppKit
import SwiftUI
import Combine

@MainActor
public final class SelectionTooltipWindowController: ObservableObject {
    public static let shared = SelectionTooltipWindowController()

    @Published public var isShowing = false

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var showWorkItem: DispatchWorkItem?
    private var dismissalMonitor: Any?
    private var appSwitchObserver: Any?
    private var timeoutWorkItem: DispatchWorkItem?
    private var orderOutWorkItem: DispatchWorkItem?

    private let panelWidth: CGFloat = 130
    private let panelHeight: CGFloat = 36

    private let electronAppPrefixes: [String] = [
        "com.google.Chrome",
        "com.microsoft.VSCode",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.electron.",
    ]

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        SelectionMonitor.shared.$currentSelection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selection in
                if let selection = selection {
                    debugLog("Tooltip: selection received, scheduling show")
                    self?.scheduleShow(for: selection)
                } else {
                    self?.dismiss()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleShow(for selection: TextSelection) {
        showWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.show(for: selection)
        }
        showWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.tooltipShowDelay, execute: workItem)
    }

    private func show(for selection: TextSelection) {
        // Don't show if comment input is visible
        guard !CommentInputController.shared.isVisible else {
            debugLog("Tooltip: not showing — comment input visible")
            return
        }

        debugLog("Tooltip: showing near \(selection.screenRect?.debugDescription ?? "mouse")")

        // Clean up any existing monitors before installing new ones
        removeDismissalMonitor()
        cancelTimeout()

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .utilityWindow


            let view = SelectionTooltipView(controller: self)
            let hostingView = NSHostingView(rootView: view)
            hostingView.sizingOptions = [.intrinsicContentSize]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            panel.contentView = hostingView

            // Resize panel to fit SwiftUI content
            let fittingSize = hostingView.fittingSize
            panel.setContentSize(fittingSize)

            self.panel = panel
        }

        let isElectron = selection.appBundleID.map { bid in
            electronAppPrefixes.contains(where: { bid.hasPrefix($0) })
        } ?? false

        if let rect = selection.screenRect, rect.width > 0, rect.height > 0 {
            position(near: rect, useMouseForHorizontal: isElectron)
        } else {
            // Fallback: position near mouse cursor
            let mouse = NSEvent.mouseLocation
            position(near: CGRect(x: mouse.x - 50, y: mouse.y, width: 100, height: 20), useMouseForHorizontal: false)
        }

        orderOutWorkItem?.cancel()
        isShowing = false
        panel?.orderFrontRegardless()

        // Kick SwiftUI animation on next runloop tick so initial state is rendered first
        DispatchQueue.main.async { [weak self] in
            self?.isShowing = true
        }

        installDismissalMonitor()
        scheduleTimeout()
    }

    public func dismiss() {
        showWorkItem?.cancel()
        showWorkItem = nil
        cancelTimeout()
        removeDismissalMonitor()

        guard let panel = panel, panel.isVisible else { return }

        isShowing = false

        // Delay orderOut until SwiftUI animation completes
        let workItem = DispatchWorkItem { [weak self] in
            panel.orderOut(nil)
            _ = self
        }
        orderOutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.tooltipFadeOutDuration + 0.05,
            execute: workItem
        )
    }

    // MARK: - Dismissal Monitoring

    private func installDismissalMonitor() {
        dismissalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalEvent(event)
            }
        }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Don't dismiss when our own app activates (e.g. activation policy change)
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            Task { @MainActor in
                debugLog("Tooltip: dismissing - app switch")
                self?.dismiss()
            }
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Ignore Cmd-modified keys (Cmd+C, Cmd+V, etc.)
            if event.modifierFlags.contains(.command) { return }
            debugLog("Tooltip: dismissing — keystroke")
            dismiss()

        case .scrollWheel:
            debugLog("Tooltip: dismissing — scroll")
            dismiss()

        case .leftMouseDown, .rightMouseDown:
            // Don't dismiss if clicking inside the tooltip
            if let panel = panel, panel.isVisible {
                let mouseLocation = NSEvent.mouseLocation
                if panel.frame.contains(mouseLocation) { return }
            }
            debugLog("Tooltip: dismissing — click outside")
            dismiss()

        default:
            break
        }
    }

    private func removeDismissalMonitor() {
        if let monitor = dismissalMonitor {
            NSEvent.removeMonitor(monitor)
            dismissalMonitor = nil
        }
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    // MARK: - Timeout

    private func scheduleTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            debugLog("Tooltip: dismissing — timeout")
            self?.dismiss()
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.tooltipTimeout,
            execute: workItem
        )
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    // MARK: - Positioning

    private func position(near selectionRect: CGRect, useMouseForHorizontal: Bool = false) {
        guard let panel = panel else { return }

        // Use actual panel size (intrinsic content sizing may differ from initial contentRect)
        let pw = panel.frame.width
        let ph = panel.frame.height
        let margin: CGFloat = 8

        // For Electron apps, use mouse position for horizontal centering
        let centerX = useMouseForHorizontal ? NSEvent.mouseLocation.x : selectionRect.midX

        let preferBelow = SettingsManager.shared.tooltipPosition == .below
        let aboveY = selectionRect.maxY + margin
        let belowY = selectionRect.minY - ph - margin

        // Position based on user preference
        var origin = NSPoint(
            x: centerX - (pw / 2),
            y: preferBelow ? belowY : aboveY
        )

        // Smart flip: if preferred position goes off-screen, use the other side.
        // Use the screen containing the selection, not NSScreen.main (keyboard-focus screen).
        let selectionMid = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        if let screen = NSScreen.screen(containing: selectionMid) ?? panel.screen ?? NSScreen.main {
            if preferBelow {
                if origin.y < screen.visibleFrame.minY {
                    origin.y = aboveY
                }
            } else {
                if origin.y + ph > screen.visibleFrame.maxY {
                    origin.y = belowY
                }
            }

            // Clamp to screen bounds horizontally
            origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - pw))
        }

        panel.setFrameOrigin(origin)
    }
}
