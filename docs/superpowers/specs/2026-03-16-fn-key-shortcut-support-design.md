# Fn/Globe Key Shortcut Support for Dictation

**Date:** 2026-03-16
**Status:** Approved

## Problem

The KeyboardShortcuts library (3rd-party, Sindre Sorhus) cannot capture or register the fn/globe key:

1. Its recorder monitors only `.keyDown` events — fn generates `.flagsChanged`
2. `Shortcut.init(event:)` explicitly strips the `.function` modifier
3. Carbon's `RegisterEventHotKey` doesn't support fn-only shortcuts
4. The fn key lives on HID usage page 0x00FF (Apple vendor top case), not the standard keyboard page

The user wants to use the fn key as a dictation shortcut (freed from WisprFlow).

## Approach

**Toggle-based UI (Approach C)** — a "Use fn🌐 key" toggle below the dictation shortcut recorders. When toggled on, the recorder is greyed out and fn becomes the active shortcut. Simpler than building a custom recorder; easy to extend later.

**CGEventTap for global fn detection** — intercepts fn `flagsChanged` events at `.cghidEventTap` level, can consume them to prevent the system's default action (input source change, emoji picker). Requires Accessibility permission, which Remarc already has.

**Intra-app shortcut conflict detection** — a `ConflictAwareRecorder` wrapper around `KeyboardShortcuts.Recorder` that detects when a newly-recorded shortcut duplicates another slot. Reverts to the previous shortcut and shows a toast. Applied to all 6 shortcut slots.

## Design

### 1. UI — Settings Toggle

For both dictation shortcut rows (Push to Talk and Hands-free Shortcut), add a "Use fn🌐 key" toggle row below the recorder. All dictation-related UI is gated behind `@available(macOS 26, *)`, matching existing code.

```
Push to talk        [  ⌘⇧D  ]
Use fn🌐 key        [toggle]

Hands-free mode     [Single Tap ▾]
  (if customShortcut mode:)
Hands-free shortcut [  record  ]
Use fn🌐 key        [toggle]
```

- Standard `settingsRow` with a `Toggle` — matches existing patterns
- When ON: the `KeyboardShortcuts.Recorder` above is `.disabled(true)` (greyed out)
- When ON: the KS shortcut for that name is cleared
- When OFF: the recorder is re-enabled, user records a new shortcut

### 2. Storage & State Management

Two new booleans in `SettingsManager`:

- `dictationUsesFnKey: Bool`
- `dictationHandsFreeUsesFnKey: Bool`

Stored in UserDefaults. **Mutual exclusion:** when one is set to `true`, the other is set to `false` with a toast: _"fn🌐 moved from Push to Talk"_ / _"fn🌐 moved from Hands-free Shortcut"_ (using the same display name mapping as ConflictAwareRecorder). The corresponding `KeyboardShortcuts` shortcut is cleared via `KeyboardShortcuts.setShortcut(nil, for:)`.

When toggled back to `false`, the recorder becomes enabled with an empty state (no automatic restore).

**Note:** `KeyboardShortcuts.setShortcut(nil, for:)` does NOT trigger the `Recorder`'s `onChange` callback (that only fires from user interaction). This means `ConflictAwareRecorder`'s `previousShortcut` state will not be updated by the fn toggle's programmatic clear. To handle this, `ConflictAwareRecorder` reads the current shortcut via `KeyboardShortcuts.getShortcut(for:)` at conflict-check time rather than relying solely on the cached `previousShortcut`. See Section 4 for details.

### 3. Global Fn Key Monitor (CGEventTap)

A `FnKeyMonitor` singleton manages the CGEventTap. All callback routing to dictation handlers is gated behind `@available(macOS 26, *)`.

**Setup:**
- `CGEvent.tapCreate` at `.cghidEventTap` + `.headInsertEventTap` + `.defaultTap`
- Listens for `.flagsChanged` events only
- Added to the main run loop as a `CFRunLoopSource`
- **Single persistent tap:** installed once at app launch, not created/destroyed per toggle change. The callback checks current settings to decide whether to consume or pass through. This avoids lifecycle bugs with rapid toggle cycling and tap creation failures.

**Callback logic:**
- Check `keyCode == 63` (`kVK_Function`) — critical to distinguish the physical fn key from F1-F12, which also set `.function` in modifier flags
- Check if `CGEventFlags.maskSecondaryFn` appeared (fn down) or disappeared (fn up)
- Only consume when an fn-based shortcut is active (`dictationUsesFnKey || dictationHandsFreeUsesFnKey`)
- If neither fn setting is active, pass the event through untouched

**fn+key combos are safe:** Key remapping (fn+Arrow→PageUp, fn+Delete→ForwardDelete, fn+F1→function key) happens at the HID driver level (`IOHIDKeyboardFilter`), before CGEventTap sees events. Consuming the `flagsChanged` event does not break these combos. Non-remapped keys (fn+H, fn+letter) will still pass through to the focused app — this is expected behavior and matches how the key works normally.

**Concurrency:** The CGEventTap callback is a C function pointer — it cannot capture `self` or call `@MainActor`-isolated methods directly. `FnKeyMonitor` uses a static/global reference pattern (standard for CGEventTap code) and dispatches to the main actor via `DispatchQueue.main.async` to invoke the `onFnKeyDown`/`onFnKeyUp` callbacks.

**Reliability:**
- Handle `CGEventTapDisabledByTimeout` by re-enabling via `CGEvent.tapEnable`
- If `CGEvent.tapCreate` returns nil (no Accessibility permission), log warning and degrade gracefully — fn shortcut simply won't work, regular shortcuts still function

**Integration with GlobalHotkey:**
- `FnKeyMonitor` exposes `onFnKeyDown` and `onFnKeyUp` callbacks
- `GlobalHotkey.register()` sets these to route to existing `handleDictationKeyDown()`/`handleDictationKeyUp()` or `handleDictationHandsFree()` depending on which setting has fn enabled
- No changes to the dictation handler logic itself — same hold detection, double-tap, and hands-free behavior

### 4. Conflict Detection (ConflictAwareRecorder)

A SwiftUI wrapper view around `KeyboardShortcuts.Recorder` that adds intra-app conflict detection to all shortcut slots.

**Display name mapping:**
```
.commentOnSelection  → "Comment on Selection"
.screenshotComment   → "Screenshot"
.pasteAllComments    → "Paste All"
.voiceInput          → "Voice Input"
.dictation           → "Push to Talk"
.dictationHandsFree  → "Hands-free Shortcut"
```

**Flow:**
1. `@State private var previousShortcut` initialized on `.onAppear` via `KeyboardShortcuts.getShortcut(for: name)`
2. Use `KeyboardShortcuts.Recorder`'s `onChange` callback
3. When a new shortcut is set, check all other names via `KeyboardShortcuts.getShortcut(for:)` for matches
4. Conflict found: read `previousShortcut` (which may be stale if fn toggle cleared the shortcut programmatically), then also verify via `KeyboardShortcuts.getShortcut(for: name)` — if that returns the conflicting shortcut, restore `previousShortcut`. Show toast _"Shortcut already used by [display name]"_
5. No conflict: update `previousShortcut` to the new value
6. Shortcut cleared by user (onChange receives nil): no conflict check, update `previousShortcut` to nil

**Edge case — programmatic clear:** When the fn toggle calls `KeyboardShortcuts.setShortcut(nil, for:)`, this does NOT trigger `onChange`. The `previousShortcut` @State may become stale. This is handled by step 4 above: on conflict, `previousShortcut` may be nil or outdated, which is acceptable — the recorder will show empty and the user re-records. The worst case is the user has to re-record a shortcut after a conflict, not data loss.

## Files

### New
- `Services/FnKeyMonitor.swift` — CGEventTap singleton for global fn detection
- `Views/ConflictAwareRecorder.swift` — SwiftUI wrapper with conflict detection

### Modified
- `Services/SettingsManager.swift` — Add `dictationUsesFnKey` and `dictationHandsFreeUsesFnKey` with mutual exclusion. Mutual exclusion logic only runs when toggling ON (`guard newValue else { return }`) to avoid unnecessary cross-property writes.
- `Utilities/GlobalHotkey.swift` — Configure `FnKeyMonitor` callbacks in `register()`/`unregister()`
- `Views/PreferencesWindowController.swift` — Replace all `KeyboardShortcuts.Recorder` with `ConflictAwareRecorder` (both Shortcuts tab and Voice section). Fn toggle rows are added only in the Voice section (not duplicated in the Shortcuts tab). Disable recorder when fn is on.

### Untouched
- KeyboardShortcuts library (3rd party)
- Dictation handler logic (handleDictationKeyDown/KeyUp/HandsFree)
- Non-preferences views
