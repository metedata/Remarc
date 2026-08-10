# Fn/Globe Key Shortcut Support — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fn/globe key as a configurable shortcut for dictation (push-to-talk and hands-free), plus intra-app shortcut conflict detection for all recorder slots.

**Architecture:** Toggle-based UI in preferences enables fn for dictation shortcuts. A CGEventTap singleton (`FnKeyMonitor`) intercepts fn globally and routes to existing dictation handlers in `GlobalHotkey`. A `ConflictAwareRecorder` SwiftUI wrapper adds conflict detection to all `KeyboardShortcuts.Recorder` instances.

**Tech Stack:** Swift 6, SwiftUI, AppKit, CoreGraphics (CGEventTap), KeyboardShortcuts library

**Spec:** `docs/superpowers/specs/2026-03-16-fn-key-shortcut-support-design.md`

**Worktree:** `.worktrees/fn-key-support` (branch `feature/fn-key-shortcut-support`)

**All file paths below are relative to:** `app/RemarcPackage/Sources/RemarcFeature/`

---

## Chunk 1: Foundation (Storage + Cleanup)

### Task 1: Delete draft file and clean worktree

**Files:**
- Delete: `Views/FnAwareRecorder.swift`

- [ ] **Step 1: Delete the draft FnAwareRecorder.swift**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
rm app/RemarcPackage/Sources/RemarcFeature/Views/FnAwareRecorder.swift
```

- [ ] **Step 2: Commit cleanup**

```bash
git add -A && git commit -m "chore: remove draft FnAwareRecorder — using toggle approach instead"
```

---

### Task 2: Add fn key settings to SettingsManager

**Files:**
- Modify: `Services/SettingsManager.swift`

- [ ] **Step 1: Add UserDefaults keys**

In the `Keys` enum (after line 61 `dictationHandsFreeMode`), add:

```swift
static let dictationUsesFnKey = "dictationUsesFnKey"
static let dictationHandsFreeUsesFnKey = "dictationHandsFreeUsesFnKey"
```

- [ ] **Step 2: Add published properties with mutual exclusion**

After the `dictationHandsFreeMode` property (after line 256), add:

```swift
@Published public var dictationUsesFnKey: Bool {
    didSet {
        defaults.set(dictationUsesFnKey, forKey: Keys.dictationUsesFnKey)
        guard dictationUsesFnKey else { return }
        // Mutual exclusion: only one fn shortcut at a time
        if dictationHandsFreeUsesFnKey {
            dictationHandsFreeUsesFnKey = false
            ToastManager.shared.show("fn🌐 moved from Hands-free Shortcut")
        }
        // Clear the KS shortcut so both don't fire
        KeyboardShortcuts.setShortcut(nil, for: .dictation)
    }
}

@Published public var dictationHandsFreeUsesFnKey: Bool {
    didSet {
        defaults.set(dictationHandsFreeUsesFnKey, forKey: Keys.dictationHandsFreeUsesFnKey)
        guard dictationHandsFreeUsesFnKey else { return }
        // Mutual exclusion: only one fn shortcut at a time
        if dictationUsesFnKey {
            dictationUsesFnKey = false
            ToastManager.shared.show("fn🌐 moved from Push to Talk")
        }
        // Clear the KS shortcut so both don't fire
        KeyboardShortcuts.setShortcut(nil, for: .dictationHandsFree)
    }
}
```

This requires adding `import KeyboardShortcuts` at the top of the file.

- [ ] **Step 3: Initialize from UserDefaults in init()**

After the `dictationHandsFreeMode` initialization block (after line 511), add:

```swift
self.dictationUsesFnKey = defaults.bool(forKey: Keys.dictationUsesFnKey)
self.dictationHandsFreeUsesFnKey = defaults.bool(forKey: Keys.dictationHandsFreeUsesFnKey)
```

- [ ] **Step 4: Build to verify**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add dictationUsesFnKey settings with mutual exclusion"
```

---

## Chunk 2: CGEventTap Monitor

### Task 3: Create FnKeyMonitor

**Files:**
- Create: `Services/FnKeyMonitor.swift`

- [ ] **Step 1: Create the FnKeyMonitor singleton**

Create `Services/FnKeyMonitor.swift` with this content:

```swift
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

    private var eventTap: CFMachPort?
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
    nonisolated(unsafe) private static var _shared: FnKeyMonitor?

    /// Whether fn events should be consumed (an fn shortcut is active).
    nonisolated var shouldConsume: Bool {
        // Read directly from UserDefaults to avoid @MainActor issues in the C callback
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "dictationUsesFnKey")
            || defaults.bool(forKey: "dictationHandsFreeUsesFnKey")
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
```

- [ ] **Step 2: Build to verify**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
git add app/RemarcPackage/Sources/RemarcFeature/Services/FnKeyMonitor.swift
git commit -m "feat: add FnKeyMonitor — CGEventTap singleton for fn/globe key detection"
```

---

## Chunk 3: GlobalHotkey Integration

### Task 4: Wire FnKeyMonitor into GlobalHotkey

**Files:**
- Modify: `Utilities/GlobalHotkey.swift`

- [ ] **Step 1: Install FnKeyMonitor and configure callbacks in register()**

In `register()` (after line 83, before the closing `debugLog` on line 84), add:

```swift
// Fn key monitor — installed once, checks settings in callback
FnKeyMonitor.shared.install()
FnKeyMonitor.shared.onFnKeyDown = { [weak self] in
    if #available(macOS 26, *) {
        Task { @MainActor in
            guard let self else { return }
            if SettingsManager.shared.dictationUsesFnKey {
                self.handleDictationKeyDown()
            } else if SettingsManager.shared.dictationHandsFreeUsesFnKey {
                self.handleDictationHandsFree()
            }
        }
    }
}
FnKeyMonitor.shared.onFnKeyUp = { [weak self] in
    if #available(macOS 26, *) {
        Task { @MainActor in
            guard let self else { return }
            if SettingsManager.shared.dictationUsesFnKey {
                self.handleDictationKeyUp()
            }
            // No keyUp handler needed for hands-free (it's a toggle)
        }
    }
}
```

**Important:** This block must go inside the existing `if #available(macOS 26, *)` block (after the dictationHandsFree registration on line 82), since the dictation handlers are `@available(macOS 26, *)`.

- [ ] **Step 2: Add FnKeyMonitor teardown in unregister()**

In `unregister()` (after line 93 `KeyboardShortcuts.disable(.dictationHandsFree)`), add:

```swift
FnKeyMonitor.shared.onFnKeyDown = nil
FnKeyMonitor.shared.onFnKeyUp = nil
```

Note: don't call `FnKeyMonitor.shared.uninstall()` here — the tap is persistent and `unregister()` is called during settings changes. The tap stays installed and routes based on current settings.

- [ ] **Step 3: Build to verify**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift
git commit -m "feat: wire FnKeyMonitor callbacks into GlobalHotkey dictation handlers"
```

---

## Chunk 4: ConflictAwareRecorder

### Task 5: Create ConflictAwareRecorder view

**Files:**
- Create: `Views/ConflictAwareRecorder.swift`

- [ ] **Step 1: Create the ConflictAwareRecorder**

Create `Views/ConflictAwareRecorder.swift`:

```swift
import KeyboardShortcuts
import SwiftUI

/// Display name mapping for all app shortcut names.
/// Used in conflict detection toasts and fn toggle toasts.
extension KeyboardShortcuts.Name {
    // KeyboardShortcuts.Name is a struct, not an enum — use if/else, not switch.
    var displayName: String {
        if self == .commentOnSelection { return "Comment on Selection" }
        if self == .screenshotComment { return "Screenshot" }
        if self == .pasteAllComments { return "Paste All" }
        if self == .voiceInput { return "Voice Input" }
        if self == .dictation { return "Push to Talk" }
        if self == .dictationHandsFree { return "Hands-free Shortcut" }
        return rawValue
    }

    /// All shortcut names that participate in conflict detection.
    static let allAppShortcuts: [KeyboardShortcuts.Name] = [
        .commentOnSelection,
        .screenshotComment,
        .pasteAllComments,
        .voiceInput,
        .dictation,
        .dictationHandsFree,
    ]
}

/// A wrapper around `KeyboardShortcuts.Recorder` that detects intra-app
/// shortcut conflicts. If a newly-recorded shortcut duplicates another slot,
/// the recorder reverts to the previous shortcut and shows a toast.
struct ConflictAwareRecorder: View {
    let name: KeyboardShortcuts.Name
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        KeyboardShortcuts.Recorder("", name: name) { newShortcut in
            guard let newShortcut else {
                // User cleared the shortcut — no conflict possible
                previousShortcut = nil
                return
            }

            // Check all other names for conflicts
            for otherName in KeyboardShortcuts.Name.allAppShortcuts where otherName != name {
                if KeyboardShortcuts.getShortcut(for: otherName) == newShortcut {
                    // Conflict found — revert to previous
                    KeyboardShortcuts.setShortcut(previousShortcut, for: name)
                    ToastManager.shared.show("Shortcut already used by \(otherName.displayName)")
                    return
                }
            }

            // No conflict — accept the new shortcut
            previousShortcut = newShortcut
        }
        .onAppear {
            previousShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
git add app/RemarcPackage/Sources/RemarcFeature/Views/ConflictAwareRecorder.swift
git commit -m "feat: add ConflictAwareRecorder with intra-app shortcut conflict detection"
```

---

## Chunk 5: Preferences UI Changes

### Task 6: Replace recorders and add fn toggles in PreferencesWindowController

**Files:**
- Modify: `Views/PreferencesWindowController.swift`

- [ ] **Step 1: Replace all KeyboardShortcuts.Recorder calls with ConflictAwareRecorder**

Replace each instance — there are 8 total across two sections. The replacement is the same for all: change `KeyboardShortcuts.Recorder("", name: .foo)` to `ConflictAwareRecorder(name: .foo)`.

**Shortcuts tab** (lines 367-391):
- Line 367: `KeyboardShortcuts.Recorder("", name: .commentOnSelection)` → `ConflictAwareRecorder(name: .commentOnSelection)`
- Line 370: `KeyboardShortcuts.Recorder("", name: .screenshotComment)` → `ConflictAwareRecorder(name: .screenshotComment)`
- Line 373: `KeyboardShortcuts.Recorder("", name: .pasteAllComments)` → `ConflictAwareRecorder(name: .pasteAllComments)`
- Line 377: `KeyboardShortcuts.Recorder("", name: .voiceInput)` → `ConflictAwareRecorder(name: .voiceInput)`
- Line 390: `KeyboardShortcuts.Recorder("", name: .dictation)` → `ConflictAwareRecorder(name: .dictation)`

**Voice section** (lines 579-623):
- Line 579: `KeyboardShortcuts.Recorder("", name: .voiceInput)` → `ConflictAwareRecorder(name: .voiceInput)`
- Line 616: `KeyboardShortcuts.Recorder("", name: .dictation)` → `ConflictAwareRecorder(name: .dictation)`
- Line 623: `KeyboardShortcuts.Recorder("", name: .dictationHandsFree)` → `ConflictAwareRecorder(name: .dictationHandsFree)`

- [ ] **Step 2: Add fn toggle for Push to Talk in Voice section**

After the "Push to talk" recorder row (after line 617), add:

```swift
toggleRow("Use fn🌐 key", isOn: $settings.dictationUsesFnKey)
```

And modify the recorder row above to disable when fn is on. Change:

```swift
settingsRow("Push to talk") {
    ConflictAwareRecorder(name: .dictation)
}
```

to:

```swift
settingsRow("Push to talk") {
    ConflictAwareRecorder(name: .dictation)
        .disabled(settings.dictationUsesFnKey)
        .opacity(settings.dictationUsesFnKey ? 0.4 : 1.0)
}
toggleRow("Use fn🌐 key", isOn: $settings.dictationUsesFnKey)
```

- [ ] **Step 3: Add fn toggle for Hands-free shortcut in Voice section**

After the hands-free recorder row (after line 624), add the fn toggle. The full `if` block becomes:

```swift
if settings.dictationHandsFreeMode == .customShortcut {
    settingsRow("Hands-free shortcut") {
        ConflictAwareRecorder(name: .dictationHandsFree)
            .disabled(settings.dictationHandsFreeUsesFnKey)
            .opacity(settings.dictationHandsFreeUsesFnKey ? 0.4 : 1.0)
    }
    toggleRow("Use fn🌐 key", isOn: $settings.dictationHandsFreeUsesFnKey)
}
```

- [ ] **Step 4: Build to verify**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Relaunch and manually verify**

```bash
pkill -x Remarc; sleep 0.5; open $REPO_ROOT/.worktrees/fn-key-support/app/DerivedData/Build/Products/Debug/Remarc.app
```

**Manual verification checklist:**
1. Open Preferences → Shortcuts tab: all 5 recorders show, typing a duplicate shortcut reverts and shows toast
2. Open Preferences → Voice section → Dictation: "Use fn🌐 key" toggle visible below "Push to talk" recorder
3. Toggle fn ON: recorder greys out, shortcut is cleared
4. Toggle fn OFF: recorder re-enables
5. If hands-free mode is "Custom Shortcut": second fn toggle visible, enabling one disables the other with toast
6. Press fn key: dictation starts (if fn toggle is ON)
7. Hold and release fn: dictation records and pastes (push-to-talk behavior)

- [ ] **Step 6: Commit**

```bash
cd $REPO_ROOT/.worktrees/fn-key-support
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add fn key toggles and conflict-aware recorders in preferences"
```
