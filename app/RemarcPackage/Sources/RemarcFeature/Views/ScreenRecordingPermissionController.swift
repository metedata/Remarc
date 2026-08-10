import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

// MARK: - Controller

@MainActor
public final class ScreenRecordingPermissionController: NSObject, ObservableObject {
    public static let shared = ScreenRecordingPermissionController()

    @Published public private(set) var state: PermissionRowState = .needsPermission
    @Published public private(set) var isVisible: Bool = false

    private var panel: NSPanel?
    private var pollingTimer: Timer?
    private var onResultCallback: ((Bool) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Check if screen recording permission is currently granted (no prompt, no side-effects).
    public func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission. Shows the permission panel if access is not yet granted.
    /// Calls `onResult` with `true` when granted, `false` if the user skips/cancels.
    public func requestPermission(onResult: @escaping (Bool) -> Void) {
        if hasPermission() {
            debugLog("ScreenRecordingPermission: Already granted")
            state = .granted
            onResult(true)
            return
        }

        onResultCallback = onResult
        state = .needsPermission
        showPanel()
    }

    /// Register the app in the TCC database and open System Settings to the Screen Recording pane.
    /// Uses SCShareableContent to register (avoids CGRequestScreenCaptureAccess which forces
    /// quit-and-reopen on macOS 15+).
    public func registerInTCCAndOpenSettings() {
        Task {
            _ = try? await SCShareableContent.current
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pre-authorize ScreenCaptureKit with a minimal 1x1 test capture.
    /// Triggers the "bypass window picker" dialog on macOS 15+ now so it
    /// won't interrupt actual screenshot capture later.
    public func preAuthorizeCapture() {
        Task {
            if let content = try? await SCShareableContent.current,
               let display = content.displays.first {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 1
                config.height = 1
                _ = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
            }
        }
    }

    /// Open System Settings to the Screen Recording privacy pane and start polling.
    public func openSystemSettings() {
        state = .waitingForGrant
        registerInTCCAndOpenSettings()
        startPolling()
    }

    /// User cancels / skips the permission request.
    public func skip() {
        stopPolling()
        dismiss()
        onResultCallback?(false)
        onResultCallback = nil
    }

    // MARK: - Panel

    private func showPanel() {
        if isVisible && state == .waitingForGrant {
            panel?.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if panel == nil {
            panel = createPanel()
        }

        guard let panel = panel else { return }

        panel.centerOnScreen()
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        isVisible = true
    }

    private func createPanel() -> NSPanel {
        let width: CGFloat = 480
        let height: CGFloat = 260

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Screen Recording Permission"
        panel.level = .floating
        panel.backgroundColor = .controlBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let size = NSSize(width: width, height: height)
        panel.minSize = size
        panel.maxSize = size

        let contentView = ScreenRecordingPermissionView()
            .environmentObject(self)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        panel.delegate = self

        return panel
    }

    private func dismiss() {
        guard let panel = panel else {
            self.panel = nil
            isVisible = false
            return
        }

        panel.fadeOut { [weak self] in
            self?.panel = nil
            self?.isVisible = false
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionPoll()
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func checkPermissionPoll() {
        if hasPermission() {
            stopPolling()
            handlePermissionGranted()
        }
    }

    private func handlePermissionGranted() {
        state = .granted
        debugLog("ScreenRecordingPermission: Granted")
        preAuthorizeCapture()

        Task {
            try? await Task.sleep(for: .seconds(0.8))
            await MainActor.run {
                self.dismiss()
                self.onResultCallback?(true)
                self.onResultCallback = nil
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension ScreenRecordingPermissionController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        skip()
        return false
    }
}

// MARK: - SwiftUI View

struct ScreenRecordingPermissionView: View {
    @EnvironmentObject var controller: ScreenRecordingPermissionController
    @Environment(\.colorScheme) var colorScheme
    @State private var isButtonHovered = false

    var body: some View {
        VStack(spacing: 20) {
            // Icon + title
            VStack(spacing: 10) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 36))
                    .foregroundColor(Color.remarcPrimary(for: colorScheme))

                Text("Screen Recording Access")
                    .font(.system(size: 18, weight: .semibold))

                Text("Remarc needs Screen Recording permission to capture screenshots of selected regions.")
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action area
            actionButton
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch controller.state {
        case .needsPermission:
            VStack(spacing: 12) {
                Button(action: { controller.openSystemSettings() }) {
                    Text("Open System Settings")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.remarcBrandGradient(for: colorScheme))
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(1.0) // hover scale disabled
                .animation(.easeInOut(duration: 0.15), value: isButtonHovered)
                .onHover { isButtonHovered = $0 }

                Button(action: { controller.skip() }) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.45))
                }
                .buttonStyle(.plain)
            }

        case .waitingForGrant:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for permission...")
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.6))
            }

        case .granted:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Permission granted")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(Color.remarcSuccess(for: colorScheme))
        }
    }
}
