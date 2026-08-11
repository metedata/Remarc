import CoreGraphics
import Foundation

/// Global fn/globe key monitor using CGEventTap.
///
/// Installed once at app launch as a persistent tap. The callback checks
/// current settings to decide whether to consume fn events or pass through.
/// Requires Accessibility permission (already granted for SelectionMonitor).
@MainActor
final class FnKeyMonitor {
    static let shared = FnKeyMonitor()

    /// Called on main thread when fn key is pressed down.
    var onFnKeyDown: (() -> Void)?
    /// Called on main thread when fn key is released.
    var onFnKeyUp: (() -> Void)?

    nonisolated(unsafe) fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

    private init() {}

    /// Install the CGEventTap. Call once at app launch.
    func install() {
        guard eventTap == nil else { return }

        // Store self in a static for the C callback
        FnKeyMonitor._shared = self

        let eventMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: fnKeyEventCallback,
            userInfo: nil
        ) else {
            debugLog("FnKeyMonitor: CGEvent.tapCreate failed — Accessibility permission missing?")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("FnKeyMonitor: installed CGEventTap")
    }

    /// Remove the CGEventTap. Call on app teardown if needed.
    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        FnKeyMonitor._shared = nil
        debugLog("FnKeyMonitor: uninstalled CGEventTap")
    }

    // Static reference for the C callback (cannot capture self)
    nonisolated(unsafe) fileprivate static var _shared: FnKeyMonitor?

    /// Whether fn events should be consumed (an fn shortcut is active and dictation is enabled).
    nonisolated var shouldConsume: Bool {
        // Read directly from UserDefaults to avoid @MainActor issues in the C callback
        let defaults = UserDefaults.standard
        guard SettingsManager.isDictationEnabled(in: defaults) else {
            return false
        }
        return defaults.bool(forKey: SettingsManager.fnKeyDictationKey)
            || defaults.bool(forKey: SettingsManager.fnKeyHandsFreeKey)
    }

    /// Handle fn state change from the C callback. Called on main thread.
    fileprivate func handleFnDown() {
        guard !fnIsDown else { return }
        fnIsDown = true
        debugLog("FnKeyMonitor: fn keyDown")
        onFnKeyDown?()
    }

    /// Handle fn release from the C callback. Called on main thread.
    fileprivate func handleFnUp() {
        guard fnIsDown else { return }
        fnIsDown = false
        debugLog("FnKeyMonitor: fn keyUp")
        onFnKeyUp?()
    }
}

// MARK: - C Callback

/// CGEventTap callback — C function pointer, cannot capture context.
private func fnKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable tap if macOS disabled it due to timeout
    if type == .tapDisabledByTimeout {
        if let tap = FnKeyMonitor._shared?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    // Check keyCode == 63 (kVK_Function) — the physical fn/globe key
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 63 else {
        return Unmanaged.passUnretained(event)
    }

    guard let monitor = FnKeyMonitor._shared, monitor.shouldConsume else {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let fnPressed = flags.contains(.maskSecondaryFn)

    DispatchQueue.main.async {
        if fnPressed {
            FnKeyMonitor._shared?.handleFnDown()
        } else {
            FnKeyMonitor._shared?.handleFnUp()
        }
    }

    // Consume the event (return nil) to prevent system fn action
    return nil
}
