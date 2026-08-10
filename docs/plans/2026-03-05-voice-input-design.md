# Voice Input Design

## Overview

Add voice-to-text input to Remarc via two entry points:

1. **Global shortcut** — press-and-hold to record while held, double-press to toggle recording on/off. Opens a comment panel (with selection reference if text is highlighted, standalone if not) and records directly into it.
2. **Mic button in comment box** — available in every comment input panel. Click to start recording, transcribed text appends to existing content.

Voice input is a text input method, not a new comment type. Comments created via voice use existing types: `.comment(text:)` when text is selected, `.quickNote` when not.

## Transcription Architecture

### Protocol Abstraction

A `TranscriptionEngine` protocol decouples recording/UI from the transcription backend:

```swift
protocol TranscriptionEngine: Sendable {
    /// Warm up the engine (model loading, resource allocation).
    func prepare() async throws

    /// Transcribe recorded audio buffers into text.
    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String
}
```

### Engines

- **`SpeechAnalyzerEngine`** — wraps the existing `SpeechTranscriber` + `SpeechAnalyzer` from the Speech framework (macOS 26+). Default engine. Requires one-time model download via `AssetInventory` on first use (system-wide, not per-app). The `prepare()` method handles this check and download.
- **`WhisperKitEngine`** (future) — wraps WhisperKit (argmaxinc/WhisperKit). Requires model download on first use (~40-150MB). Better for specialized/technical vocabulary.

Engine selection is a `SettingsManager` property. CritModeService can also be migrated to use this protocol to unify transcription across both features.

### Audio Capture

Reuse the existing `AudioCaptureEngine` pattern from CritModeService:
- `AVAudioEngine` with input node tap
- Captures `AVAudioPCMBuffer` arrays + RMS levels for waveform visualization
- Non-MainActor isolation for the realtime audio thread

A new `VoiceInputService` owns the `AudioCaptureEngine` instance and the `TranscriptionEngine`, coordinating the record-transcribe-deliver flow.

## Global Shortcut

### Registration

Add a new `KeyboardShortcuts.Name`:

```swift
static let voiceInput = Self(
    "voiceInput",
    default: .init(.v, modifiers: [.command, .shift])
)
```

The default is Cmd+Shift+V, but the user can remap to any key in preferences — including a single function key (e.g., F16) with no modifiers. The KeyboardShortcuts library supports modifier-free shortcuts natively (`modifiers` defaults to `[]`). This enables Wispr-Flow-style setups where a dedicated physical button triggers voice input.

### Interaction Model

Uses both `onKeyDown` and `onKeyUp` plus a timestamp to detect intent:

- **Press-and-hold**: `onKeyDown` starts recording, `onKeyUp` stops recording. Detected when key is held longer than a threshold (~0.4s).
- **Double-press**: Two `onKeyDown` events within a short window (~0.4s). First press starts recording, second press stops it. If already recording when the shortcut fires again, stop recording.

State tracking in `GlobalHotkey`:

```
onKeyDown:
  if recording → stop recording
  else → record keyDownTime, start recording, open comment panel

onKeyUp:
  if recording AND (now - keyDownTime > holdThreshold) → stop recording
  else → no-op (it was a tap, recording continues until next press)
```

### Comment Panel Behavior

When the shortcut fires:
1. Read current selection via `SelectionMonitor` (may be nil)
2. Open `CommentInputController` — either `showForSelection()` or `showStandaloneNote()`
3. Immediately enter the warming-up state on the panel's voice input

## Comment Box UI

### Mic Button

A microphone button is added to the comment input toolbar (next to existing controls like attachment). Clicking it triggers the same voice input flow as the global shortcut, but within the already-open panel.

### Recording State Machine

The comment input panel tracks five states for voice input:

```
idle → warmingUp → recording → processing → idle
```

**1. Idle**
- Save button: normal appearance (checkmark/save icon)
- Mic button: visible in toolbar, ready to tap
- No window border accent

**2. Warming Up**
- Save button: shows a small spinner/loading indicator
- Window border: accent outline appears (static `remarcPrimary`)
- Text area: untouched
- Triggered by: shortcut press or mic button tap
- Transitions to: recording (when engine is ready)

**3. Recording**
- Save button area: transforms into a **mini waveform** — live audio level bars (reusing `AudioWaveformView` pattern) reactive to mic input. On hover, the waveform morphs into a **stop icon** (square), clickable to stop.
- Window border: accent outline (subtle, static or slow pulse)
- Text area: completely untouched — existing text remains visible and editable
- Duration: not displayed (keeping it minimal)
- Triggered by: engine ready
- Transitions to: processing (on stop via hover-click, shortcut release, or second shortcut press)

**4. Processing**
- Save button: returns to normal save appearance
- Window border: accent outline fades out
- Text area: a small inline loading indicator appears:
  - If text editor is empty: centered spinner or "Transcribing..." placeholder
  - If text exists: indicator appears at the end of the existing text, showing that text is about to be appended
- Triggered by: recording stopped, buffers sent to TranscriptionEngine
- Transitions to: idle (when transcription completes)

**5. Done (back to Idle)**
- Transcribed text is appended to the editor content
- Loading indicator removed
- All UI back to normal idle state
- User can edit the text, record again, or save

### Window Border

When in warmingUp or recording state, the comment input panel's window gets a subtle border:
- Use `remarcPrimary` color as a rounded rect stroke matching the panel's corner radius
- Applied as an overlay on the SwiftUI content, inside the VEV
- Removed when returning to idle

### Waveform-in-Button

The save button area (~28-32pt) hosts a miniature version of the audio waveform:
- 5-7 vertical bars, same reactive behavior as `AudioWaveformView`
- Colored with `remarcPrimary` or recording-red
- On mouse hover: bars fade/scale down, a stop square icon appears (smooth transition)
- On click while hovered: stops recording

## VoiceInputService

Central service managing the voice input lifecycle:

```swift
@MainActor
@Observable
final class VoiceInputService {
    enum State { case idle, warmingUp, recording, processing }

    private(set) var state: State = .idle
    private(set) var audioLevels: [Float] = []

    private var engine: AudioCaptureEngine?
    private var transcriptionEngine: TranscriptionEngine
    private var recordedBuffers: [AVAudioPCMBuffer] = []

    func startRecording() async throws { ... }
    func stopRecording() async throws -> String { ... }
}
```

- `startRecording()`: transitions idle → warmingUp → recording. Calls `transcriptionEngine.prepare()`, then starts `AudioCaptureEngine`.
- `stopRecording()`: transitions recording → processing → idle. Stops capture, feeds buffers to `transcriptionEngine.transcribe()`, returns the text.
- `audioLevels` published for waveform visualization (same RMS approach as CritMode).
- Singleton or injected into `CommentInputController`.

## Data Flow Summary

```
User action (shortcut / mic button tap)
  |
  v
GlobalHotkey / CommentInputView
  |
  v
VoiceInputService.startRecording()
  |-- prepare TranscriptionEngine
  |-- start AudioCaptureEngine (captures buffers + RMS levels)
  |-- publish audioLevels → waveform UI
  |
  v
User stops (release key / press again / click stop)
  |
  v
VoiceInputService.stopRecording()
  |-- stop AudioCaptureEngine
  |-- feed buffers to TranscriptionEngine.transcribe()
  |-- return transcribed text
  |
  v
CommentInputView
  |-- append text to editor
  |-- user edits / saves as normal
  |
  v
CommentInputController.saveComment()
  |-- .comment(text:) if selection exists
  |-- .quickNote if no selection
```

## Research Validation

All technical assumptions verified (March 2026):

- **KeyboardShortcuts** (sindresorhus): `onKeyDown(for:action:)` and `onKeyUp(for:action:)` confirmed. Single-key shortcuts (no modifiers) supported natively. Async `events(for:)` stream also available.
- **SpeechAnalyzer** (WWDC25 session 277): `start(inputSequence:)` is the correct method for buffer-based input. `AnalyzerInput(buffer: pcmBuffer)` wraps buffers. Works well for short recordings. Minimal warm-up after initial model download.
- **Asset downloads**: Speech models must be explicitly downloaded via `AssetInventory.assetInstallationRequest(supporting:)` before first use. Models are system-wide. Locale limit applies. Current CritModeService has a placeholder for this — both features should handle it properly.
- **AVAudioEngine**: `installTap(onBus:bufferSize:format:)` on inputNode is the standard mic capture pattern. Already proven in CritModeService's `AudioCaptureEngine`.
- **Microphone permissions**: Already configured — `NSMicrophoneUsageDescription` in Info.plist, `com.apple.security.device.audio-input` entitlement in place.
- **macOS 26 availability**: VoiceInputService requires `@available(macOS 26, *)` — same as CritModeService.

## Scope Boundaries

**In scope:**
- Global shortcut with press-and-hold + double-press detection
- Mic button in comment input toolbar
- VoiceInputService with AudioCaptureEngine
- TranscriptionEngine protocol + SpeechAnalyzerEngine implementation
- Recording state UI (waveform button, window border, processing indicator)
- Appending transcribed text to editor

**Out of scope (future):**
- WhisperKitEngine implementation
- Settings UI for engine selection
- Audio file storage / playback
- Streaming/live transcription (text appears as you speak)
- CritModeService migration to TranscriptionEngine protocol
