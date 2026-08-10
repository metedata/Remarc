# Configurable Shortcut for Comment Input

**Date:** 2026-02-27
**Status:** Approved

## Problem

The global hotkey (Cmd+Shift+C) for invoking the comment box is hardcoded and currently disabled because it conflicts with Figma. The `NSEvent.addGlobalMonitorForEvents` approach cannot consume events, so the foreground app always receives the keypress too.

## Solution

Replace the `NSEvent` global monitor in `GlobalHotkey` with [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), which wraps Carbon's `RegisterEventHotKey`. This registers shortcuts at the OS level so the foreground app never sees the keypress. Add a `KeyboardShortcuts.Recorder` in Settings for the user to configure their preferred shortcut.

## Behavior

- **Shortcut + text selected:** Read selection via AX/clipboard cascade, open comment input panel directly (skip tooltip).
- **Shortcut + no selection:** Open standalone quick note.
- **Default shortcut:** Cmd+Shift+C (changeable in Settings > General).

## Architecture

### Files Changed

| File | Change |
|------|--------|
| `Package.swift` | Add `KeyboardShortcuts` SPM dependency |
| `GlobalHotkey.swift` | Replace `NSEvent` monitor with `KeyboardShortcuts.onKeyDown` handler |
| `PreferencesWindowController.swift` | Add `KeyboardShortcuts.Recorder` row in General tab |
| `AppController.swift` | Uncomment / re-enable `GlobalHotkey.shared.register()` |

### Data Flow

```
User presses configured shortcut
  → Carbon RegisterEventHotKey consumes event (foreground app never sees it)
  → KeyboardShortcuts calls GlobalHotkey handler
  → SelectionMonitor.readCurrentSelection() — one-shot AX/clipboard read
  → Selection found: CommentInputController.showForSelection(selection)
  → No selection: CommentInputController.showStandaloneNote()
```

### Settings Flow

```
Preferences > General tab
  → KeyboardShortcuts.Recorder shows current shortcut
  → User clicks recorder, types new combo
  → KeyboardShortcuts validates, persists to UserDefaults, re-registers Carbon hotkey
  → GlobalHotkey picks up the change automatically
```

### What Doesn't Change

- `SelectionMonitor`, `TextReader`, `CommentInputController` — untouched
- Tooltip-based auto-detection flow — still works independently
- `SelectionDetectionMode` (.auto / .hotkeyOnly) — still valid

## Dependencies

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (SPM) — wraps Carbon hotkey API, provides SwiftUI recorder, handles persistence and conflict detection
