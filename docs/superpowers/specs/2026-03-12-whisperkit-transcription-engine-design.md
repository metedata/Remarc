# WhisperKit Transcription Engine

Add WhisperKit as an optional on-device transcription engine, selectable via a new Voice tab in Preferences. Apple Speech remains the default; WhisperKit offers higher accuracy using OpenAI's Whisper models running locally via CoreML.

## Motivation

The existing `TranscriptionEngine` protocol was designed for swappable backends (the protocol file even notes `// Future: WhisperKitEngine`). Apple Speech (~8% WER) is adequate but WhisperKit's Whisper models offer significantly better accuracy (1-8% WER depending on model size), especially for accented speech, technical vocabulary, and noisy environments. Adding WhisperKit as an alternative gives users a choice between convenience (Apple Speech, zero setup) and quality (WhisperKit, one-time model download).

## Scope

**In scope:**
- WhisperKit SPM dependency and `WhisperKitEngine` implementation
- New Voice tab in Preferences with engine selection, model picker, download management, shortcut, and behavior settings
- Engine selection applies to both voice input (comment dictation) and Crit Mode
- Graceful fallback to Apple Speech when WhisperKit model is unavailable

**Out of scope:**
- Cloud-based transcription (OpenAI Whisper API) — potential Phase 2
- Streaming/real-time partial transcription — batch-only for now
- Language selection — English-only models initially

## Data Model

### New Enums (`Models/TranscriptionEngineType.swift`)

```swift
enum TranscriptionEngineType: String, CaseIterable, Identifiable {
    case appleSpeech = "Apple Speech"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }
}

enum WhisperKitModelSize: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case accurate = "Accurate"

    var id: String { rawValue }

    var modelIdentifier: String {
        switch self {
        case .fast: return "openai_whisper-tiny.en"
        case .balanced: return "openai_whisper-small.en"
        case .accurate: return "openai_whisper-large-v3"
        }
    }

    var downloadSizeMB: Int {
        switch self {
        case .fast: return 75
        case .balanced: return 217
        case .accurate: return 947
        }
    }

    var label: String {
        switch self {
        case .fast: return "Fast (75 MB)"
        case .balanced: return "Balanced (217 MB)"
        case .accurate: return "Accurate (947 MB)"
        }
    }
}
```

### New Settings (`Services/SettingsManager.swift`)

```swift
@Published var transcriptionEngine: TranscriptionEngineType  // default: .appleSpeech
@Published var whisperKitModel: WhisperKitModelSize           // default: .balanced
```

Persisted to `UserDefaults` like existing settings.

### No Changes to Data Layer

`Comment`, `AppState`, `CommentType` are unchanged. The transcription engine is transparent — it produces text, the rest of the pipeline doesn't care which engine produced it.

## Engine Architecture

### Existing Protocol (unchanged)

```swift
@available(macOS 26, *)
protocol TranscriptionEngine: Sendable {
    func prepare() async throws
    func transcribe(buffers: [AVAudioPCMBuffer], inputFormat: AVAudioFormat) async throws -> String
}
```

### New: `WhisperKitEngine` (`Services/WhisperKitEngine.swift`)

Conforms to `TranscriptionEngine`. Key behaviors:

- **`prepare()`**: Downloads model from HuggingFace if not cached, initializes WhisperKit pipeline. Emits download progress via a published property for Settings UI. Uses `WhisperKitConfig(modelFolder:)` to override the default storage location.
- **`transcribe(buffers:inputFormat:)`**: Converts `[AVAudioPCMBuffer]` to 16kHz mono Float32 array, runs WhisperKit batch transcription, returns text string.
- **Model storage**: `~/Library/Application Support/Remarc/models/` — uses WhisperKit's `modelFolder` config option to override the default `~/Documents/huggingface/` location.
- **Memory management**: Loads model on first transcription. Unloads after 60 seconds of inactivity to keep the menu bar app lightweight. Rapid back-to-back recordings reuse the loaded model without re-loading. Load/unload is guarded by an actor to prevent races (e.g., a transcription request arriving exactly as the unload timer fires).
- **Sendable conformance**: `WhisperKitEngine` is implemented as an `actor` to safely wrap WhisperKit's mutable pipeline state while satisfying the protocol's `Sendable` requirement.

### Engine Factory

Small factory function used by `VoiceInputService`:

```swift
@available(macOS 26, *)
enum TranscriptionEngineFactory {
    static func createEngine() -> any TranscriptionEngine {
        switch SettingsManager.shared.transcriptionEngine {
        case .appleSpeech:
            return SpeechAnalyzerEngine()
        case .whisperKit:
            return WhisperKitEngine(model: SettingsManager.shared.whisperKitModel)
        }
    }
}
```

### VoiceInputService Integration

`VoiceInputService` currently stores the engine as `private let transcriptionEngine: any TranscriptionEngine = SpeechAnalyzerEngine()`. This changes to a computed property that reads the current setting each time a transcription starts:

```swift
private var transcriptionEngine: any TranscriptionEngine {
    TranscriptionEngineFactory.createEngine()
}
```

This means changing the engine in Settings takes effect on the next recording — no app restart needed. Each transcription gets a fresh engine instance, but `WhisperKitEngine` internally uses a shared actor-isolated model cache so the model isn't reloaded per-call.

### CritModeService Integration

`CritModeService` does **not** use the `TranscriptionEngine` protocol. It has its own inline `SpeechAnalyzer`/`SpeechTranscriber` integration that returns `[String]` (an array of speech segments), not a single `String`. These per-segment boundaries feed into the Foundation Models segmentation pipeline for splitting critique recordings into individual comments.

**Approach:** Add a second method to `WhisperKitEngine` specifically for CritModeService:

```swift
/// Transcribe and return individual segments (for Crit Mode).
func transcribeSegments(
    buffers: [AVAudioPCMBuffer],
    inputFormat: AVAudioFormat
) async throws -> [String]
```

This uses WhisperKit's `TranscriptionResult.segments` to return per-segment text, preserving the segment boundaries that Crit Mode's Foundation Models pipeline expects. The `TranscriptionEngine` protocol is **not** modified — this is a `WhisperKitEngine`-specific method.

`CritModeService.transcribe()` changes from always calling `_transcribeWithSpeechAnalyzer()` to:

```swift
private func transcribe() async throws -> [String] {
    switch SettingsManager.shared.transcriptionEngine {
    case .appleSpeech:
        return try await _transcribeWithSpeechAnalyzer()
    case .whisperKit:
        let engine = WhisperKitEngine(model: SettingsManager.shared.whisperKitModel)
        return try await engine.transcribeSegments(
            buffers: recordedBuffers,
            inputFormat: savedInputFormat!
        )
    }
}
```

The existing `_transcribeWithSpeechAnalyzer()` and all its helper methods remain unchanged as the Apple Speech path.

## Model Download & Error Handling

### Download States

| State | UI |
|---|---|
| Not downloaded | Model size label + "Download" button |
| Downloading | Progress bar with percentage + "Cancel" button |
| Downloaded | Checkmark + "Delete" button to reclaim disk space |
| Failed | Error message + "Retry" button |

### Edge Cases

| Scenario | Behavior |
|---|---|
| Network failure mid-download | Error with "Retry". Partial download cleaned up. Falls back to Apple Speech. |
| User cancels download | Partial file deleted. Engine stays on / reverts to Apple Speech. |
| Disk space insufficient | Check before starting. Show "Not enough disk space (need X MB)" warning. |
| Switch model while downloading | Cancel current download, start new one. |
| Select WhisperKit before model ready | Setting saves immediately. Transcription falls back to Apple Speech. Info text: "Using Apple Speech until model is ready." |
| Transcription triggered during download | Falls back to Apple Speech silently. No interruption to recording flow. |
| App quit during download | Attempts to resume on next launch if WhisperKit is still selected (HuggingFace Hub supports resumable downloads). Falls back to restarting from scratch if resume fails. |
| Model file corrupted / deleted externally | Detected on next `prepare()`. Re-downloads automatically. Settings UI resets to "Not downloaded." |
| Switch models (old → new) | Old model file deleted after new model finishes downloading — always keeps a working model on disk. |

### Key Principle

WhisperKit is never a hard dependency. Apple Speech is always available as a fallback. The user's recording flow is never blocked by download state.

## Preferences UI — Voice Tab

### Sidebar Position

Between Shortcuts and Export (3rd tab, index 2). SF Symbol icon: `waveform`. The `SettingsSection` enum case must be inserted between `.shortcuts` and `.export` so `CaseIterable` iteration renders the sidebar in the correct order.

### Sections

**Transcription Engine**
- Picker: "Apple Speech" / "WhisperKit"
- Info box explaining both options:
  - Apple Speech — Built-in macOS transcription. No download required. Good accuracy, fully private.
  - WhisperKit — On-device Whisper model. Higher accuracy, downloads model on first use.

**WhisperKit Model** (enabled only when WhisperKit is selected, dimmed otherwise)
- Model picker: "Fast (75 MB)" / "Balanced (217 MB)" / "Accurate (947 MB)"
- Download state indicator (per edge case table above)
- Fallback notice when model not ready: "Using Apple Speech until model is ready"

**Shortcut**
- `KeyboardShortcuts.Recorder` for `.voiceInput` — same binding as Shortcuts tab. Changing in either tab reflects immediately in the other (both bind to the same `SettingsManager` property).

**Behavior**
- Auto-save voice notes toggle — duplicated from Shortcuts tab, same `SettingsManager.autoSaveVoiceNotes` property
- Auto-save delay picker — shown when auto-save is on, same `SettingsManager.autoSaveDelay` property

## SPM Dependency

```swift
// In Package.swift
.package(url: "https://github.com/argmaxinc/whisperkit", from: "0.16.0")

// In target dependencies
.product(name: "WhisperKit", package: "whisperkit")
```

WhisperKit is MIT licensed. It pulls in `swift-transformers` and `huggingface-hub` as transitive dependencies. Verify the latest stable version at implementation time — WhisperKit is actively developed and API surfaces may change.

## Files Changed

### New Files
- `Services/WhisperKitEngine.swift` — TranscriptionEngine conformance, model download, load/unload lifecycle
- `Models/TranscriptionEngineType.swift` — `TranscriptionEngineType` and `WhisperKitModelSize` enums

### Modified Files
- `Package.swift` — add WhisperKit SPM dependency
- `Services/SettingsManager.swift` — add `transcriptionEngine` and `whisperKitModel` properties
- `Services/VoiceInputService.swift` — change `private let transcriptionEngine` from hardcoded `SpeechAnalyzerEngine()` to computed property using `TranscriptionEngineFactory`
- `Services/CritModeService.swift` — add engine switch in `transcribe()` to dispatch to either existing `_transcribeWithSpeechAnalyzer()` or new `WhisperKitEngine.transcribeSegments()`. All existing Speech framework helper methods remain unchanged.
- `Views/PreferencesWindowController.swift` — add `.voice` case to `SettingsSection` enum (between `.shortcuts` and `.export`), add `voiceSection` view, insert sidebar entry

### Unchanged Files
- `Services/TranscriptionEngine.swift` — protocol unchanged
- `Services/SpeechAnalyzerEngine.swift` — untouched
- `Services/AudioCaptureEngine.swift` — captures audio the same way regardless of engine
- `Models/Comment.swift`, `Models/AppState.swift` — engine is transparent to data layer
