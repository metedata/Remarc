# WhisperKit Transcription Engine Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add WhisperKit as an optional on-device transcription engine, selectable via a new Voice tab in Preferences.

**Architecture:** WhisperKit conforms to the existing `TranscriptionEngine` protocol. A factory selects the active engine based on user settings. CritModeService gets a parallel integration path via a `transcribeSegments()` method. A new Voice tab in Preferences consolidates engine, model, shortcut, and behavior settings.

**Tech Stack:** WhisperKit (SPM), CoreML, AVFAudio, SwiftUI, KeyboardShortcuts

**Spec:** `docs/superpowers/specs/2026-03-12-whisperkit-transcription-engine-design.md`

---

## Chunk 1: Data Model + SPM Dependency + Settings

### Task 1: Add WhisperKit SPM Dependency

**Files:**
- Modify: `app/RemarcPackage/Package.swift`

- [ ] **Step 1: Add WhisperKit package dependency**

In `Package.swift`, add to the `dependencies` array (after the KeyboardShortcuts line):

```swift
.package(url: "https://github.com/argmaxinc/whisperkit", from: "0.16.0")
```

And add to the target's `dependencies` array (after KeyboardShortcuts):

```swift
.product(name: "WhisperKit", package: "whisperkit")
```

- [ ] **Step 2: Verify SPM resolution**

Run: `cd app && xcodebuild -resolvePackageDependencies -workspace Remarc.xcworkspace -scheme Remarc`

Expected: Resolves successfully, downloads WhisperKit + transitive deps (swift-transformers, huggingface-hub).

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Package.swift
git commit -m "feat: add WhisperKit SPM dependency"
```

### Task 2: Create Transcription Engine Enums

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Models/TranscriptionEngineType.swift`

- [ ] **Step 1: Create the enum file**

```swift
import Foundation

enum TranscriptionEngineType: String, CaseIterable, Identifiable, Sendable {
    case appleSpeech = "Apple Speech"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }
}

enum WhisperKitModelSize: String, CaseIterable, Identifiable, Sendable {
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

- [ ] **Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/TranscriptionEngineType.swift
git commit -m "feat: add TranscriptionEngineType and WhisperKitModelSize enums"
```

### Task 3: Add Settings Properties

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add UserDefaults keys**

In the `Keys` enum, add at the end of the block (after the `webContextIdentityEnabled` key, around line 51):

```swift
static let transcriptionEngine = "transcriptionEngine"
static let whisperKitModel = "whisperKitModel"
```

- [ ] **Step 2: Add published properties**

Add after the `webContextIdentityEnabled` property (around line 199), before the `launchAtLogin` computed property:

```swift
@Published public var transcriptionEngine: TranscriptionEngineType {
    didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
}

@Published public var whisperKitModel: WhisperKitModelSize {
    didSet { defaults.set(whisperKitModel.rawValue, forKey: Keys.whisperKitModel) }
}
```

- [ ] **Step 3: Initialize from UserDefaults**

In `init()`, at the end of the initializer (after the `webContextIdentityEnabled` init, around line 392), add:

```swift
if let saved = defaults.string(forKey: Keys.transcriptionEngine),
   let engine = TranscriptionEngineType(rawValue: saved) {
    self.transcriptionEngine = engine
} else {
    self.transcriptionEngine = .appleSpeech
}

if let saved = defaults.string(forKey: Keys.whisperKitModel),
   let model = WhisperKitModelSize(rawValue: saved) {
    self.whisperKitModel = model
} else {
    self.whisperKitModel = .balanced
}
```

- [ ] **Step 4: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add transcriptionEngine and whisperKitModel settings"
```

---

## Chunk 2: WhisperKitEngine Implementation

### Task 4: Implement WhisperKitEngine

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/WhisperKitEngine.swift`

- [ ] **Step 1: Create the WhisperKitEngine actor**

```swift
import AVFAudio
import Foundation
import WhisperKit

// MARK: - Model Manager (MainActor, for Settings UI)

/// Manages WhisperKit model downloads, caching, and lifecycle.
/// Lives on MainActor so PreferencesView can call methods synchronously.
/// No @available(macOS 26, *) — WhisperKit supports macOS 14+,
/// and this class doesn't use any macOS 26 APIs directly.
@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(message: String)
    }

    /// Download state for the currently-selected model.
    /// Refreshed via refreshDownloadState(for:) on model change.
    @Published var downloadState: DownloadState = .notDownloaded

    /// The model identifier currently being downloaded (if any).
    /// Used to prevent stale progress updates when user switches models.
    private var activeDownloadModelID: String?
    private var downloadTask: Task<WhisperKit?, Never>?

    /// Cached WhisperKit instances keyed by model identifier.
    private var cache: [String: WhisperKit] = [:]
    private var unloadTasks: [String: Task<Void, Never>] = [:]

    private static let unloadDelay: TimeInterval = 60

    static var modelDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("Remarc/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir.path
    }

    func isModelDownloaded(_ model: WhisperKitModelSize) -> Bool {
        let modelPath = URL(fileURLWithPath: Self.modelDirectory)
            .appendingPathComponent(model.modelIdentifier)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    func deleteModel(_ model: WhisperKitModelSize) {
        let modelPath = URL(fileURLWithPath: Self.modelDirectory)
            .appendingPathComponent(model.modelIdentifier)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            cache.removeValue(forKey: model.modelIdentifier)
            unloadTasks[model.modelIdentifier]?.cancel()
            unloadTasks.removeValue(forKey: model.modelIdentifier)
            try? FileManager.default.removeItem(at: modelPath)
            downloadState = .notDownloaded
            debugLog("WhisperKitModelManager: Deleted model \(model.modelIdentifier)")
        }
    }

    func refreshDownloadState(for model: WhisperKitModelSize) {
        // If this model is actively downloading, don't overwrite the progress
        if activeDownloadModelID == model.modelIdentifier {
            return
        }
        downloadState = isModelDownloaded(model) ? .downloaded : .notDownloaded
    }

    /// Cancel any in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeDownloadModelID = nil
        downloadState = .notDownloaded
        debugLog("WhisperKitModelManager: Download cancelled")
    }

    /// Get or load a WhisperKit instance for the given model.
    /// Downloads the model if not cached. Returns nil on failure (caller should fall back).
    func getOrLoadModel(_ model: WhisperKitModelSize) async -> WhisperKit? {
        let modelID = model.modelIdentifier

        // Cancel pending unload
        unloadTasks[modelID]?.cancel()
        unloadTasks.removeValue(forKey: modelID)

        // Return cached
        if let cached = cache[modelID] {
            debugLog("WhisperKitModelManager: Using cached model \(modelID)")
            return cached
        }

        // Cancel any existing download for a different model
        if let activeID = activeDownloadModelID, activeID != modelID {
            cancelDownload()
        }

        // Load (may download)
        debugLog("WhisperKitModelManager: Loading model \(modelID)")
        activeDownloadModelID = modelID
        downloadState = .downloading(progress: 0)
        do {
            let config = WhisperKitConfig(
                model: model.modelIdentifier,
                downloadBase: Self.modelDirectory,
                verbose: false,
                prewarm: true
            )
            // NOTE: Verify WhisperKit's actual progress callback API at implementation time.
            // WhisperKitConfig may support a `progressCallback` or similar parameter
            // to report download progress. Wire it up to update downloadState:
            //   progressCallback: { progress in
            //       Task { @MainActor in
            //           self.downloadState = .downloading(progress: progress)
            //       }
            //   }
            let kit = try await WhisperKit(config)

            // Check for cancellation (user may have switched models during download)
            guard activeDownloadModelID == modelID else {
                debugLog("WhisperKitModelManager: Download completed but model was switched")
                return nil
            }

            cache[modelID] = kit
            activeDownloadModelID = nil
            downloadState = .downloaded
            debugLog("WhisperKitModelManager: Model \(modelID) loaded")
            return kit
        } catch {
            activeDownloadModelID = nil
            if Task.isCancelled {
                downloadState = .notDownloaded
            } else {
                downloadState = .failed(message: error.localizedDescription)
            }
            debugLog("WhisperKitModelManager: Failed to load model \(modelID): \(error)")
            return nil
        }
    }

    /// Schedule model unload after idle timeout.
    func scheduleUnload(for model: WhisperKitModelSize) {
        let modelID = model.modelIdentifier
        unloadTasks[modelID]?.cancel()
        unloadTasks[modelID] = Task {
            try? await Task.sleep(for: .seconds(Self.unloadDelay))
            guard !Task.isCancelled else { return }
            cache.removeValue(forKey: modelID)
            unloadTasks.removeValue(forKey: modelID)
            debugLog("WhisperKitModelManager: Unloaded model \(modelID) after \(Self.unloadDelay)s idle")
        }
    }
}

// MARK: - WhisperKitEngine (TranscriptionEngine conformance)

/// On-device Whisper transcription engine using WhisperKit.
/// Conforms to TranscriptionEngine for use with VoiceInputService.
/// Also provides transcribeSegments() for CritModeService.
@available(macOS 26, *)
struct WhisperKitEngine: TranscriptionEngine, Sendable {
    let modelSize: WhisperKitModelSize

    init(model: WhisperKitModelSize) {
        self.modelSize = model
    }

    func prepare() async throws {
        // Pre-load via the model manager. If download fails, transcribe()
        // will fall back to Apple Speech via the factory.
        let _ = await WhisperKitModelManager.shared.getOrLoadModel(modelSize)
    }

    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String {
        guard let kit = await WhisperKitModelManager.shared.getOrLoadModel(modelSize) else {
            // Model not available — fall back to Apple Speech
            debugLog("WhisperKitEngine: Model unavailable, falling back to Apple Speech")
            let fallback = SpeechAnalyzerEngine()
            try await fallback.prepare()
            return try await fallback.transcribe(buffers: buffers, inputFormat: inputFormat)
        }

        let audioArray = Self.convertBuffersToFloatArray(buffers: buffers, inputFormat: inputFormat)
        guard !audioArray.isEmpty else { return "" }

        let result = try await kit.transcribe(audioArray: audioArray)
        await WhisperKitModelManager.shared.scheduleUnload(for: modelSize)
        return result.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - CritModeService Integration

    /// Transcribe and return individual segments (for Crit Mode).
    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String] {
        guard let kit = await WhisperKitModelManager.shared.getOrLoadModel(modelSize) else {
            // Model not available — fall back to Apple Speech is handled by CritModeService caller
            debugLog("WhisperKitEngine: Model unavailable for segments")
            return []
        }

        let audioArray = Self.convertBuffersToFloatArray(buffers: buffers, inputFormat: inputFormat)
        guard !audioArray.isEmpty else { return [] }

        let results = try await kit.transcribe(audioArray: audioArray)
        await WhisperKitModelManager.shared.scheduleUnload(for: modelSize)

        // Each TranscriptionResult contains segments; flatten them
        var segments: [String] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(text)
                }
            }
        }

        // If no segments were found but we got top-level text, use that
        if segments.isEmpty {
            let fullText = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fullText.isEmpty {
                segments.append(fullText)
            }
        }

        return segments
    }

    // MARK: - Audio Conversion

    /// Convert AVAudioPCMBuffer array to 16kHz mono Float32 array for WhisperKit.
    private static func convertBuffersToFloatArray(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            debugLog("WhisperKitEngine: Failed to create target format")
            return []
        }

        var allSamples: [Float] = []

        for buffer in buffers {
            guard buffer.frameLength > 0 else { continue }

            if inputFormat.sampleRate == 16000 && inputFormat.channelCount == 1 {
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    allSamples.append(contentsOf: UnsafeBufferPointer(
                        start: channelData[0], count: frameCount
                    ))
                }
            } else {
                guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    debugLog("WhisperKitEngine: Failed to create converter")
                    continue
                }

                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: estimatedFrames
                ) else { continue }

                var error: NSError?
                var consumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if let error {
                    debugLog("WhisperKitEngine: Conversion error: \(error)")
                    continue
                }

                if let channelData = convertedBuffer.floatChannelData {
                    let frameCount = Int(convertedBuffer.frameLength)
                    allSamples.append(contentsOf: UnsafeBufferPointer(
                        start: channelData[0], count: frameCount
                    ))
                }
            }
        }

        debugLog("WhisperKitEngine: Converted \(buffers.count) buffers → \(allSamples.count) samples")
        return allSamples
    }
}
```

**Note:** The exact WhisperKit API (e.g., `WhisperKitConfig` parameter names, `transcribe(audioArray:)` return type) should be verified against the installed version at implementation time. Check the WhisperKit README or source for the correct API. The structure above follows v0.16.0 conventions but may need minor adjustments.

- [ ] **Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED. If WhisperKit API has changed, adjust the code to match the installed version.

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/WhisperKitEngine.swift
git commit -m "feat: implement WhisperKitEngine with TranscriptionEngine conformance"
```

---

## Chunk 3: Wire Engine into VoiceInputService + CritModeService

### Task 5: Add TranscriptionEngineFactory and Update VoiceInputService

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/VoiceInputService.swift`

- [ ] **Step 1: Add TranscriptionEngineFactory**

Add at the top of the file (after the `VoiceInputState` enum, before `VoiceInputService`):

```swift
@available(macOS 26, *)
enum TranscriptionEngineFactory {
    @MainActor
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

- [ ] **Step 2: Change transcriptionEngine to a stored optional, set per-session**

In `VoiceInputService`, replace line 25:

```swift
private let transcriptionEngine: any TranscriptionEngine = SpeechAnalyzerEngine()
```

with:

```swift
/// Engine for the current recording session. Set in startRecording(),
/// used in stopRecording(). Per-session so settings changes take effect
/// on the next recording without requiring app restart.
private var transcriptionEngine: (any TranscriptionEngine)?
```

Then in `startRecording()` (around line 51), add at the top of the method (after the `guard state == .idle` check):

```swift
// Create engine for this session — reads current setting
transcriptionEngine = TranscriptionEngineFactory.createEngine()
```

And update the `prepare()` call to use the new optional:

```swift
do {
    try await transcriptionEngine?.prepare()
} catch {
```

And in `stopRecording()`, update the `transcribe` call:

```swift
guard let engine = transcriptionEngine else {
    debugLog("VoiceInputService: No transcription engine")
    setState(.idle)
    return ""
}
// ...
let text = try await engine.transcribe(
    buffers: buffersToTranscribe,
    inputFormat: format
)
```

After transcription completes (in both success and error paths), clear the engine:

```swift
transcriptionEngine = nil
```

- [ ] **Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/VoiceInputService.swift
git commit -m "feat: wire TranscriptionEngineFactory into VoiceInputService"
```

### Task 6: Update CritModeService

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift`

- [ ] **Step 1: Update the `transcribe()` method**

Replace the existing `transcribe()` method (line 176-178):

```swift
private func transcribe() async throws -> [String] {
    return try await _transcribeWithSpeechAnalyzer()
}
```

with:

```swift
private func transcribe() async throws -> [String] {
    switch SettingsManager.shared.transcriptionEngine {
    case .appleSpeech:
        return try await _transcribeWithSpeechAnalyzer()
    case .whisperKit:
        guard let inputFormat = savedInputFormat else {
            debugLog("CritModeService: No input format saved for WhisperKit")
            return []
        }
        let engine = WhisperKitEngine(model: SettingsManager.shared.whisperKitModel)
        try await engine.prepare()
        let segments = try await engine.transcribeSegments(
            buffers: recordedBuffers,
            inputFormat: inputFormat
        )
        // Fall back to Apple Speech if WhisperKit returned nothing
        // (e.g., model unavailable, download failed)
        if segments.isEmpty {
            debugLog("CritModeService: WhisperKit returned empty, falling back to Apple Speech")
            return try await _transcribeWithSpeechAnalyzer()
        }
        return segments
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift
git commit -m "feat: add WhisperKit engine path in CritModeService transcription"
```

---

## Chunk 4: Voice Tab in Preferences

### Task 7: Add Voice Section to SettingsSection Enum

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add `.voice` case to `SettingsSection` enum**

Insert between `.shortcuts` and `.export` (line 120-121):

```swift
case voice = "Voice"
```

So the enum becomes:

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case voice = "Voice"
    case export = "Export"
    case chromeExtension = "Chrome Extension"
    case excludedApps = "Excluded Apps"
    case license = "License"
    case about = "About"
    // ...
}
```

- [ ] **Step 2: Add icon for the voice case**

In the `icon` computed property, add before the `.export` case:

```swift
case .voice: return "waveform"
```

- [ ] **Step 3: Add the voice section switch case**

In the `body` `Group` switch (around line 162-170), add between `.shortcuts` and `.export`:

```swift
case .voice: voiceSection
```

- [ ] **Step 4: Build to verify (will fail — `voiceSection` not yet defined, that's expected)**

Proceed to next step.

### Task 8: Implement Voice Section View

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add `@ObservedObject` for WhisperKitModelManager**

In `PreferencesView`, add a new observed object alongside the existing ones (around line 103):

```swift
@ObservedObject private var modelManager = WhisperKitModelManager.shared
```

- [ ] **Step 1b: Add the voiceSection computed property**

Add after `shortcutsSection` (after line 345), before the `// MARK: - Settings Design System` comment:

```swift
    @available(macOS 26, *)
    private var voiceSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                // Transcription Engine
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Transcription Engine", description: "Choose which engine converts speech to text.")

                    pickerRow("Engine", selection: $settings.transcriptionEngine) { $0.rawValue }

                    // Info box
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                            Text("Apple Speech")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("— Built-in macOS transcription. No download required. Good accuracy, fully private.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                            Text("WhisperKit")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("— On-device Whisper model. Higher accuracy, downloads model on first use.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.remarcPrimary(for: colorScheme).opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                            )
                    )
                }

                Divider()

                // WhisperKit Model
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("WhisperKit Model", description: "Select model size. Larger models are more accurate but use more memory.")

                    pickerRow("Model", selection: $settings.whisperKitModel) { $0.label }

                    // Download status — driven by WhisperKitModelManager
                    switch modelManager.downloadState {
                    case .downloaded:
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                            Text("Downloaded")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                            Spacer()
                            Button("Delete") {
                                modelManager.deleteModel(settings.whisperKitModel)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                            .buttonStyle(.plain)
                        }
                    case .downloading(let progress):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                ProgressView(value: progress)
                                    .tint(Color.remarcPrimary(for: colorScheme))
                                Button("Cancel") {
                                    modelManager.cancelDownload()
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.plain)
                            }
                            Text("Downloading... \(Int(progress * 100))%")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                    case .failed(let message):
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 11))
                            Text("Download failed: \(message)")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                            Spacer()
                            Button("Retry") {
                                Task {
                                    let _ = await modelManager.getOrLoadModel(settings.whisperKitModel)
                                }
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                        }
                    case .notDownloaded:
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.primary.opacity(0.4))
                                .font(.system(size: 11))
                            Text("Not downloaded — will download on first use (\(settings.whisperKitModel.downloadSizeMB) MB)")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                    }

                    if settings.transcriptionEngine == .whisperKit
                        && modelManager.downloadState != .downloaded {
                        settingsHint(
                            "Using Apple Speech until model is ready.",
                            icon: "info.circle.fill",
                            tint: Color.remarcInfo(for: colorScheme)
                        )
                    }
                }
                .opacity(settings.transcriptionEngine == .whisperKit ? 1.0 : 0.35)
                .disabled(settings.transcriptionEngine != .whisperKit)
                .onChange(of: settings.whisperKitModel) { _, newModel in
                    modelManager.refreshDownloadState(for: newModel)
                }
                .onAppear {
                    modelManager.refreshDownloadState(for: settings.whisperKitModel)
                }

                Divider()

                // Shortcut
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Shortcut", description: "Keyboard shortcut for voice input. Also editable in the Shortcuts tab.")

                    settingsRow("Voice Input") {
                        KeyboardShortcuts.Recorder("", name: .voiceInput)
                    }
                }

                Divider()

                // Behavior
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Behavior", description: "Voice input behavior settings.")

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Auto-save voice notes", isOn: $settings.autoSaveVoiceNotes)
                        Text("Automatically saves comments created with the voice shortcut. Does not apply to comments invoked manually.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.autoSaveVoiceNotes {
                        pickerRow("Auto-save delay", selection: $settings.autoSaveDelay) { $0.label }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
```

- [ ] **Step 2: Wrap the voice case in the switch with availability check**

The `voiceSection` uses `@available(macOS 26, *)`, so in the switch statement, wrap it:

```swift
case .voice:
    if #available(macOS 26, *) {
        voiceSection
    }
```

- [ ] **Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Relaunch and verify visually**

Run: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Open Settings. Verify:
- Voice tab appears in sidebar between Shortcuts and Export
- All four sections render correctly
- Engine picker defaults to "Apple Speech"
- WhisperKit Model section is dimmed when Apple Speech is selected
- Switching to WhisperKit un-dims the model section
- Shortcut recorder shows current voice input binding
- Auto-save toggle and delay match the values in Shortcuts tab

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add Voice tab to Preferences with engine, model, shortcut, and behavior settings"
```

---

## Chunk 5: Build, Test, and Verify End-to-End

### Task 9: Clean Build and Manual Verification

- [ ] **Step 1: Clean build**

Run: `cd app && xcodebuild clean build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Reset TCC and relaunch**

```bash
tccutil reset Microphone com.metepolat.Remarc
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Grant microphone access when prompted.

- [ ] **Step 3: Verify Apple Speech still works**

1. Open Settings > Voice — confirm Engine is "Apple Speech"
2. Use Cmd+Shift+V to record a voice note
3. Verify transcription works as before (no regressions)

- [ ] **Step 4: Verify WhisperKit engine**

1. Open Settings > Voice — switch Engine to "WhisperKit"
2. Confirm model section is enabled, shows "Not downloaded"
3. Use Cmd+Shift+V to record a voice note
4. On first use, WhisperKit will download the model (check `/tmp/remarc_debug.log` for progress)
5. Verify transcription completes and text appears
6. Check Settings > Voice — model should now show "Downloaded"

- [ ] **Step 5: Verify Crit Mode with WhisperKit**

1. With WhisperKit still selected, start a Crit Mode session
2. Speak a few sentences, stop recording
3. Verify multiple comment segments are created (not one merged block)

- [ ] **Step 6: Verify settings sync**

1. Change the voice shortcut in Settings > Voice
2. Verify it updates in Settings > Shortcuts
3. Change auto-save toggle in Settings > Voice
4. Verify it updates in Settings > Shortcuts

- [ ] **Step 7: Verify fallback behavior**

1. Switch to WhisperKit with a model that isn't downloaded (e.g., switch to "Accurate")
2. Try recording immediately — should fall back to Apple Speech
3. Check `/tmp/remarc_debug.log` for fallback log messages
