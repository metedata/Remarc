import AppKit
import Combine

/// Coordinates NSApplication activation policy transitions between `.accessory` (no Dock icon)
/// and `.regular` (Dock icon visible, Mission Control participation).
///
/// Window controllers call `register`/`unregister` when showing/hiding windows
/// that need Dock presence. The user's "Show in Dock" preference overrides dynamic switching.
@MainActor
public final class ActivationPolicyManager {
    public static let shared = ActivationPolicyManager()

    private var registeredOwners: Set<ObjectIdentifier> = []
    private var settingsCancellable: AnyCancellable?

    private init() {
        settingsCancellable = SettingsManager.shared.$showInDock
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePolicy()
            }
        // Apply initial policy (handles showInDock=true on launch)
        updatePolicy()
    }

    /// Register a window owner that needs the Dock icon visible.
    public func register(_ owner: AnyObject) {
        registeredOwners.insert(ObjectIdentifier(owner))
        updatePolicy()
    }

    /// Unregister a window owner. When none remain (and showInDock is off), reverts to .accessory.
    public func unregister(_ owner: AnyObject) {
        registeredOwners.remove(ObjectIdentifier(owner))
        updatePolicy()
    }

    private func updatePolicy() {
        let shouldBeRegular = SettingsManager.shared.showInDock || !registeredOwners.isEmpty
        let currentPolicy = NSApp.activationPolicy()

        if shouldBeRegular && currentPolicy != .regular {
            applyPolicy(.regular, activate: true)
        } else if !shouldBeRegular && currentPolicy == .regular {
            applyPolicy(.accessory, activate: false)
        }
    }

    private func applyPolicy(_ policy: NSApplication.ActivationPolicy, activate: Bool) {
        // Protect existing floating panels from being hidden during the switch
        let protectedWindows = NSApp.windows.filter { $0.level.rawValue > NSWindow.Level.normal.rawValue }
        protectedWindows.forEach { $0.canHide = false }

        NSApp.setActivationPolicy(policy)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            protectedWindows.forEach { $0.canHide = true }
        }
    }
}
