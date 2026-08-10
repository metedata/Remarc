# Dictation Mode — Design Spec

## Problem

Remarc ties all audio transcription to comment creation. Users who want general-purpose dictation — transcribing speech into any focused text field — must use separate paid apps like Wispr Flow or Superwhisper ($10+/mo). Remarc already has the local transcription infrastructure (WhisperKit, Parakeet, Apple Speech). Adding a standalone dictation mode leverages this investment, expands Remarc's value proposition, and captures interest from the large dictation market.

## Solution

A standalone **Dictation Mode** that transcribes speech directly into any focused text field. No comment, no session, no selection required. Triggered by `Cmd+Shift+D` with two interaction modes (hold-to-record and double-tap persistent), visualized as a floating pill at center-bottom of screen, with transcription history in the popover.

## Requirements

- macOS 26+ only (same gate as existing voice input)
- Reuses existing transcription engine infrastructure
- Does not create comments — transcriptions are a separate data type
- Pastes transcribed text via clipboard + CGEvent Cmd+V
- Preserves user's clipboard around the paste operation
- Mutual exclusion with voice input and crit mode (only one audio mode at a time)

---

## Interaction Model

### Hotkey: `Cmd+Shift+D`

Single hotkey, gesture-driven mode selection:

```
keyDown → pill appears + recording starts (always)
  │
  ├─ keyUp after ≥0.4s (HOLD)
  │   └─ stop → transcribe → paste → dismiss
  │
  └─ keyUp after <0.4s (TAP)
      ├─ stop recording, pill stays visible (~0.5s window)
      │
      ├─ second keyDown within window (DOUBLE-TAP)
      │   └─ restart recording in persistent mode
      │      pill transitions: add Stop + Cancel buttons
      │      records until Stop clicked or hotkey pressed again
      │      stop → transcribe → paste → dismiss
      │
      └─ no second keyDown (SINGLE TAP)
          └─ transcribe brief recording → paste → dismiss
```

### Remarc Editor Focus Passthrough

When the user is focused inside a Remarc comment editor panel (`CommentInputController.shared.isVisible` and the panel is key window), the dictation hotkey delegates to the editor's native recording controls instead of showing the dictation pill. This avoids two competing UIs.

---

## Dictation Pill UI

### Panel Architecture

Floating `NSPanel` following the established pattern:

- `styleMask: [.borderless, .nonactivatingPanel]` — must NOT steal focus from target text field
- `level: .floating`
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `NSVisualEffectView` as `contentView` with `.popover` material, `.behindWindow` blend, `.active` state
- Pill-shaped `maskImage` (cornerRadius = half panel height)
- `NSHostingView` pinned via Auto Layout constraints
- No SwiftUI `.background(.regularMaterial)` — VEV provides it

**Position:** Center-bottom of active screen, ~60pt from bottom edge.

### Appear/Dismiss Animation

Matches the selection tooltip pattern:
- **Appear:** blur 3→0, scale 0.92→1.0, opacity 0→1, `.easeOut(duration: 0.1)`
- **Dismiss:** blur 0→3, scale 1.0→0.92, opacity 1→0, `.easeOut(duration: 0.1)`

### Audio Feedback

Subtle sounds on:
- Recording start (pill appears)
- Recording stop (before transcription)

### Visual States

#### Hold Mode (no buttons)

| State | Content |
|-------|---------|
| Warming up | Spinner + "Preparing..." |
| Recording | MiniWaveformView + "Listening..." |
| Processing | Spinner + "Transcribing..." |

#### Persistent Mode (with buttons)

| State | Content |
|-------|---------|
| Warming up | Spinner + "Preparing..." |
| Recording | MiniWaveformView + "Listening..." \| divider \| Stop button \| Cancel button |
| Processing | Spinner + "Transcribing..." |

### Audio-Reactive Background

Inner fill inside the pill, matching `VoiceRecordingBorder`:
- `LinearGradient(indigo→violet)` with `.plusLighter` blend mode
- Intensity = `min(level * 32, 1.0)`
- Base alpha: 0.08 (dark) / 0.05 (light), active alpha: base + 0.12 * intensity
- Animated at `.easeOut(0.1s)` matching 30fps drain timer
- Static accent border: `remarcPrimary` at 0.5 opacity, 1.5pt

### Buttons (Persistent Mode)

**Stop button:**
- 28pt circle, `remarcBrandGradient` fill (indigo→violet)
- White square icon (10pt, 2pt radius)
- Hover: scale 1.08, brighter gradient, shadow glow
- Tooltip on hover: "Stop & transcribe" (native `.help()` modifier)

**Cancel button:**
- 28pt circle, `white.opacity(0.08)` fill
- White "✕" at 0.5 opacity
- Hover: scale 1.08, fill brightens to 0.14, border appears
- Tooltip on hover: "Cancel (discard)"
- Action: discard all audio, no transcription, no history entry, dismiss pill

### Escape Key

Cancels recording and dismisses pill (same as Cancel button).

---

## Data Model

### `Transcription` struct

```swift
struct Transcription: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var appBundleID: String?
    var appName: String?
    let createdAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}
```

No session, no status, no attachments. Just text + context.

### AppState changes

- Add `var transcriptions: [Transcription]` (default `[]`)
- Backward-compatible Codable: `decodeIfPresent` defaulting to `[]`
- Only encode if non-empty

### PersistenceManager changes

- `transcriptions` computed property (non-deleted, newest first)
- `addTranscription(text:appBundleID:appName:) -> Transcription`
- `deleteTranscription(_ id:)` — soft-delete
- `permanentlyDeleteTranscription(_ id:)` — hard-delete
- Extend `pruneExpiredHistory()` to prune transcriptions

### Settings changes

- `transcriptionRetentionDays: Int` (default 7 days)

---

## DictationService

Separate `@MainActor ObservableObject` singleton, following `VoiceInputService` pattern.

### State Machine

```
idle → warmingUp (0.8s min) → recording → processing (1.0s min) → idle
```

Plus a `persistentMode: Bool` flag that controls whether the pill shows buttons.

### Responsibilities

- Owns its own `AudioCaptureEngine` instance
- Creates transcription engine via `TranscriptionEngineFactory`
- Publishes `state` and `audioLevels` for UI
- `startRecording()` — prepare engine, start capture, drain timer
- `stopRecording() async throws -> String` — stop capture, transcribe, return text
- `cancelRecording()` — discard everything, reset to idle
- Pauses media via `MediaRemoteController` (same as voice input)

### Mutual Exclusion

- `startRecording()` cancels any active `VoiceInputService` or `CritModeService`
- Those services cancel `DictationService` when they start

---

## Hotkey & Paste Logic

### GlobalHotkey changes

- Register `KeyboardShortcuts.Name.dictation` (default `Cmd+Shift+D`, macOS 26+)
- `onKeyDown` / `onKeyUp` handlers with tap/hold/double-tap detection
- `dictationKeyDownTime: Date?` for hold detection
- `awaitingSecondTap: Bool` for double-tap detection
- `secondTapTimer: DispatchWorkItem?` for double-tap window timeout

### Paste flow (`stopDictationAndPaste()`)

1. `let text = try await DictationService.shared.stopRecording()`
2. Guard non-empty
3. Save current clipboard contents (`NSPasteboard.general.pasteboardItems`)
4. `PersistenceManager.shared.addTranscription(text:appBundleID:appName:)`
5. Write text to `NSPasteboard.general`
6. Simulate `Cmd+V` via `CGEvent` (same pattern as `handlePasteAllHotkey()`)
7. After 200ms delay, restore original clipboard contents
8. Dismiss pill

---

## Transcription History

### Popover Integration

Segmented control in history header: "Comments" | "Transcriptions"

```
┌─────────────────────────────────┐
│ ← [Comments | Transcriptions] 🔍↕ │
├─────────────────────────────────┤
│                                 │
│   Transcription cards...        │
│                                 │
└─────────────────────────────────┘
```

When "Transcriptions" is selected, `TranscriptionHistoryView` replaces `CommentHistoryView`.

### TranscriptionHistoryView

Shows **all transcriptions** (not just deleted — this is a usage log). Newest first by default.

- Search by text content
- Sort toggle (newest/oldest)
- Empty state: "No transcriptions yet" with Cmd+Shift+D hint

### TranscriptionCardView

Each card shows:
- Transcription text (3-line limit, expandable on tap)
- Metadata: relative timestamp + app name (e.g., "2 hours ago · VS Code")
- Hover-reveal actions: Copy button, Delete button (with confirmation)

Styling follows `HistoryCardView` patterns.

---

## Settings

### Preferences additions

- **Shortcuts section:** `KeyboardShortcuts.Recorder` for dictation shortcut
- **Retention section:** "Transcription retention" dropdown after "Image retention"
  - Options: 1 day, 7 days, 30 days, 90 days

---

## Files

### New files (4)

| File | Purpose |
|------|---------|
| `Models/Transcription.swift` | Data model |
| `Services/DictationService.swift` | Recording + transcription orchestrator |
| `Views/DictationPillController.swift` | NSPanel pill + DictationPillView SwiftUI |
| `Views/TranscriptionHistoryView.swift` | History list + TranscriptionCardView |

### Modified files (7)

| File | Changes |
|------|---------|
| `Models/AppState.swift` | Add `transcriptions` field with backward-compatible Codable |
| `Services/PersistenceManager.swift` | Transcription CRUD + prune logic |
| `Services/SettingsManager.swift` | `transcriptionRetentionDays` setting |
| `Utilities/GlobalHotkey.swift` | Register `.dictation`, handlers, paste logic, double-tap detection |
| `Views/PopoverContentView.swift` | History tab segmented control |
| `Services/VoiceInputService.swift` | Cancel dictation on start (mutual exclusion) |
| `Services/CritModeService.swift` | Cancel dictation on start (mutual exclusion) |

### Reused (no changes)

- `AudioCaptureEngine` — audio capture
- `TranscriptionEngineFactory` / `TranscriptionEngine` — engine abstraction
- `MiniWaveformView` — waveform in pill
- `MediaRemoteController` — media pause/resume
- CGEvent Cmd+V paste pattern — from `handlePasteAllHotkey()`
- NSPanel + VEV + maskImage pattern — from `MenuBarPopoverController`

---

## Edge Cases

- **No text field focused:** Dictation activates regardless. Text goes to clipboard + paste. If no field accepts it, it's still in transcription history.
- **Very short recording (single tap):** May produce empty text. If empty, dismiss silently without pasting or saving to history.
- **Concurrent audio modes:** Mutual exclusion — starting dictation cancels voice input/crit mode and vice versa.
- **Remarc editor focused:** Hotkey delegates to editor's native recording instead of showing pill.
- **Clipboard restoration:** Original clipboard restored ~200ms after paste. If paste fails (no focused field), clipboard still gets restored.
