import AppKit
import AVFAudio
import SwiftUI
import ApplicationServices

@MainActor
public final class OnboardingWindowController: NSObject, ObservableObject {
    public static let shared = OnboardingWindowController()

    @Published public private(set) var accessibilityState: PermissionRowState = .needsPermission
    @Published public private(set) var microphoneState: PermissionRowState = .needsPermission
    @Published public private(set) var screenRecordingState: PermissionRowState = .needsPermission
    @Published public private(set) var isVisible: Bool = false

    private var window: NSWindow?
    private var accessibilityPollingTimer: Timer?
    private var screenRecordingPollingTimer: Timer?

    public var onComplete: ((_ hasPermission: Bool) -> Void)?

    public var allPermissionsGranted: Bool {
        accessibilityState == .granted && microphoneState == .granted && screenRecordingState == .granted
    }

    private override init() {
        super.init()
    }

    public func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func checkMicrophonePermission() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    public func show() {
        if checkAccessibilityPermission() {
            accessibilityState = .granted
        }
        if checkMicrophonePermission() {
            microphoneState = .granted
        }
        if ScreenRecordingPermissionController.shared.hasPermission() {
            screenRecordingState = .granted
        }

        if isVisible {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if window == nil {
            window = createWindow()
        }

        guard let window else { return }

        window.centerOnScreen()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        isVisible = true
        ActivationPolicyManager.shared.register(self)
    }

    // MARK: - Permission Requests

    public func requestAccessibility() {
        accessibilityState = .waitingForGrant
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startAccessibilityPolling()
    }

    public func requestMicrophone() {
        microphoneState = .waitingForGrant
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.microphoneState = granted ? .granted : .needsPermission
                if granted {
                    debugLog("Onboarding: Microphone permission granted")
                }
            }
        }
    }

    public func requestScreenRecording() {
        screenRecordingState = .waitingForGrant
        ScreenRecordingPermissionController.shared.registerInTCCAndOpenSettings()
        startScreenRecordingPolling()
    }

    public func continueFromOnboarding() {
        finish(hasPermission: true)
    }

    /// Hides the window without completing onboarding. User can bring it back via menu bar.
    public func hide() {
        guard isVisible, let window else { return }
        window.fadeOut { [weak self] in
            guard let self else { return }
            self.isVisible = false
            ActivationPolicyManager.shared.unregister(self)
        }
    }

    /// Re-shows the window if it was hidden or minimized.
    public func bringBack() {
        guard let window else {
            show()
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !isVisible {
            isVisible = true
            ActivationPolicyManager.shared.register(self)
        }
    }

    private func finish(hasPermission: Bool) {
        stopAllPolling()
        dismiss()
        onComplete?(hasPermission)
    }

    // MARK: - Window

    private func createWindow() -> NSWindow {
        let width = AppConstants.onboardingWindowWidth
        let height = AppConstants.onboardingWindowHeight

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.level = .normal
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.title = "Remarc Permissions"

        let size = NSSize(width: width, height: height)
        window.minSize = size
        window.maxSize = size

        let contentView = OnboardingContentView()
            .environmentObject(self)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        window.delegate = self

        return window
    }

    // MARK: - Polling

    private func startAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibilityPoll()
            }
        }
    }

    private func startScreenRecordingPolling() {
        screenRecordingPollingTimer?.invalidate()
        screenRecordingPollingTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkScreenRecordingPoll()
            }
        }
    }

    private func stopAllPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
        screenRecordingPollingTimer?.invalidate()
        screenRecordingPollingTimer = nil
    }

    private func checkAccessibilityPoll() {
        if checkAccessibilityPermission() {
            accessibilityPollingTimer?.invalidate()
            accessibilityPollingTimer = nil
            accessibilityState = .granted
            debugLog("Onboarding: Accessibility permission granted")
        }
    }

    private func checkScreenRecordingPoll() {
        if ScreenRecordingPermissionController.shared.hasPermission() {
            screenRecordingPollingTimer?.invalidate()
            screenRecordingPollingTimer = nil
            screenRecordingState = .granted
            debugLog("Onboarding: Screen recording permission granted")
            ScreenRecordingPermissionController.shared.preAuthorizeCapture()
        }
    }

    private func dismiss() {
        stopAllPolling()

        guard let window else {
            self.window = nil
            isVisible = false
            return
        }

        ActivationPolicyManager.shared.unregister(self)

        window.fadeOut { [weak self] in
            self?.window = nil
            self?.isVisible = false
        }
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
