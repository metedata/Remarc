# Auto-Save Voice Notes

## Overview

Add an opt-in setting that automatically saves comments created via the voice input shortcut. After transcription completes, the Save button fills over 2 seconds and then the comment auto-saves. Any interaction during the fill cancels auto-save and keeps the panel open for manual editing.

This only applies to voice-invoked comments (via the voice hotkey). Comments created manually via tooltip, text selection shortcut, or screenshot shortcut are not affected.

**Availability**: macOS 26+ only (same as voice input). All UI and logic for this feature must be gated behind `#available(macOS 26, *)`.

## Setting

- **Property**: `autoSaveVoiceNotes: Bool` in `SettingsManager` (default `false`)
- **Persistence**: `UserDefaults.standard` key `"autoSaveVoiceNotes"`
- **Location**: Preferences → Shortcuts section, directly below the Voice Input hotkey recorder, inside the same `#available(macOS 26, *)` gate
- **Label**: "Auto-save voice notes"
- **Subtitle**: "Automatically saves comments created with the voice shortcut. Does not apply to comments invoked manually."

## Invocation Source Tracking

`CommentInputController` needs to know whether the current comment was voice-invoked:

- New `@Published` property: `isVoiceInvoked: Bool` (default `false`)
- Set by `GlobalHotkey.handleVoiceInputKeyDown()` — it calls `CommentInputController.shared.showForSelection()` or `showStandaloneNote()` first, then sets `isVoiceInvoked = true` after (so the show methods don't reset it)
- All `show*` entry points (`showForSelection`, `showForScreenshot`, `showForWebElement`, `showStandaloneNote`) set `isVoiceInvoked = false` at the top of their body
- Reset to `false` on panel dismiss

Auto-save triggers only when both `isVoiceInvoked == true` and `autoSaveVoiceNotes == true`.

## Auto-Save Flow

When enabled and voice-invoked:

1. Recording stops → transcription completes → text appears in input field
2. If transcription is non-empty, a 2-second countdown begins (managed by `CommentInputController`)
3. After 2 seconds, the comment saves and the panel dismisses (same genie animation as manual save)
4. If transcription is empty, no auto-save — panel stays open in manual mode

## Auto-Save Timer

The timer lives in `CommentInputController` (stable `ObservableObject`), not in the SwiftUI view:

- New `@Published` property: `autoSaveCountdownActive: Bool` (drives the fill animation in the view)
- New `@Published` property: `autoSaveProgress: Double` (0.0 → 1.0, updated at ~60fps for smooth fill)
- Private `Task` reference for the countdown, cancelled on `cancelAutoSave()`
- `startAutoSaveCountdown()`: starts a 2s task that increments `autoSaveProgress` and calls `saveComment()` at completion
- `cancelAutoSave()`: cancels the task, resets progress to 0, sets `autoSaveCountdownActive = false`, triggers shake

## Save Button Fill Animation

- Left-to-right fill using the brand gradient (`remarcBrandGradient`)
- 2-second linear duration, driven by `autoSaveProgress` from the controller
- Fill acts as a progress indicator — visually communicates "about to save"
- Implemented as an overlay layer on the existing Save button, clipped by width fraction matching `autoSaveProgress`

## Cancellation

During the 2-second fill, any interaction cancels auto-save:

- **Escape**: Cancels auto-save, keeps panel open (does NOT dismiss). Requires `KeyablePanel.cancelOperation(_:)` to check `controller.autoSaveCountdownActive` — if active, call `controller.cancelAutoSave()` instead of dismissing.
- **Clicking anywhere in the panel**: Cancels. Use `NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown)` installed when countdown starts, removed when countdown ends or is cancelled. The monitor calls `cancelAutoSave()` and returns the event (does not swallow it, so the click still reaches its target).
- **Typing**: Cancels. Watch `commentText` changes via `.onChange` in the view, but only during the countdown period (`autoSaveCountdownActive == true`). The transcription text is set before the countdown starts, so any `commentText` change during the countdown is user-initiated.

On cancellation:

1. Fill animation stops and resets immediately
2. Save button performs a subtle horizontal shake (~3pt amplitude, 2–3 oscillations, ~0.4s duration)
3. Panel stays open in normal manual mode — user can edit and save as usual

## Shake Animation

A horizontal offset animation on the Save button:

- Amplitude: ~3pt
- Pattern: right → left → right → center (2–3 oscillations)
- Duration: ~0.4s
- Spring-based for natural feel
- Triggered only on cancellation of auto-save
- Driven by a `@Published` `shakeAutoSave: Bool` on the controller, observed by the view

## Implementation Scope

### Files to modify

1. **`SettingsManager.swift`** — Add `autoSaveVoiceNotes` property
2. **`PreferencesWindowController.swift`** — Add toggle in Shortcuts section (inside `#available(macOS 26, *)` gate)
3. **`CommentInputController.swift`** — Add `isVoiceInvoked` flag, auto-save timer logic (`autoSaveCountdownActive`, `autoSaveProgress`, `shakeAutoSave`), `startAutoSaveCountdown()`, `cancelAutoSave()`
4. **`CommentInputView.swift`** — Fill animation overlay on Save button, shake modifier, `.onChange(of: commentText)` cancellation during countdown
5. **`GlobalHotkey.swift`** — Set `controller.isVoiceInvoked = true` after calling show methods in `handleVoiceInputKeyDown()`
6. **`KeyablePanel.swift`** (or wherever `cancelOperation` is overridden) — Check for active countdown before dismissing

### No new files needed

All changes fit within existing files.

## Edge Cases

- **Setting toggled while panel is open**: No effect on current panel — only applies to next voice invocation
- **Multiple voice recordings in one session**: Each transcription completion restarts the 2s timer. There is no way to know which recording is "final" — if the user doesn't record again within 2s, it auto-saves
- **Panel opened via voice, then user manually records again**: New transcription cancels the existing countdown and starts a fresh one
- **Empty transcription**: No auto-save, panel stays in manual mode
- **Voice recording still in progress**: Auto-save only starts after transcription completes (processing → idle transition)
- **Reduce Motion**: When `accessibilityReduceMotion` is enabled, replace fill animation with a text countdown on the Save button label (e.g., "Saving... 2s")
