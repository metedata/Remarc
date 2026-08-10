# Voice Input Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add voice-to-text input via global shortcut (press-and-hold / double-press) and mic button in comment box, using SpeechAnalyzer with a swappable engine protocol.

**Architecture:** Extract `AudioCaptureEngine` to its own file. Create `TranscriptionEngine` protocol with `SpeechAnalyzerEngine` implementation. Build `VoiceInputService` to coordinate recording + transcription. Add recording UI states to `CommentInputView` (waveform-in-save-button, accent border, processing indicator). Wire via `GlobalHotkey` with `onKeyDown`/`onKeyUp` for hold/tap detection.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSPanel), Speech framework (SpeechAnalyzer/SpeechTranscriber), AVAudioEngine, KeyboardShortcuts library

**Design doc:** `docs/plans/2026-03-05-voice-input-design.md`

---

### Task 1: Extract AudioCaptureEngine to its own file

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/AudioCaptureEngine.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift`

**Step 1: Create AudioCaptureEngine.swift**

Move the `AudioCaptureEngine` class (lines 1-79 of CritModeService.swift) to its own file. Keep all imports it needs.

```swift
import AVFAudio
import Accelerate
import Foundation

// MARK: - Audio Capture Engine (runs outside MainActor to avoid isolation checks in tap closure)

/// Owns the AVAudioEngine and installs the tap on a non-MainActor context.
/// This prevents Swift 6 from inserting MainActor isolation checks in the
/// `installTap` closure, which runs on the realtime audio thread.
@available(macOS 26, *)
final class AudioCaptureEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(Float, AVAudioPCMBuffer)] = []
    private var engine: AVAudioEngine?
    private(set) var inputFormat: AVAudioFormat?

    /// Set up and start the audio engine + tap. Must be called off MainActor.
    /// Reuses the existing AVAudioEngine if available — creating a second
    /// instance after tearing down the first causes the tap to silently stop
    /// firing on macOS.
    func start() throws {
        let eng: AVAudioEngine
        if let existing = engine {
            existing.inputNode.removeTap(onBus: 0)
            if existing.isRunning { existing.stop() }
            eng = existing
        } else {
            eng = AVAudioEngine()
        }
        self.engine = eng

        // Clear stale pending data from previous recording
        lock.lock()
        pending = []
        lock.unlock()

        let inputNode = eng.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        self.inputFormat = format

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))

            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            memcpy(copy.floatChannelData![0], channelData[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            if buffer.format.channelCount > 1, let dst = copy.floatChannelData?[1], let src = buffer.floatChannelData?[1] {
                memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }

            self.append(rms: rms, buffer: copy)
        }

        try eng.start()
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // Keep engine alive for reuse — do NOT set to nil
    }

    func append(rms: Float, buffer: AVAudioPCMBuffer) {
        lock.lock()
        pending.append((rms, buffer))
        lock.unlock()
    }

    func drain() -> [(Float, AVAudioPCMBuffer)] {
        lock.lock()
        let result = pending
        pending = []
        lock.unlock()
        return result
    }
}
```

**Step 2: Remove AudioCaptureEngine from CritModeService.swift**

Delete lines 1-79 (the `import AVFAudio`, `import Accelerate`, `AudioCaptureEngine` class) from CritModeService.swift. Keep the `import Foundation` and everything from `// MARK: - Crit Mode State` onward. Add `import AVFAudio` back to CritModeService.swift since it uses `AVAudioPCMBuffer` and `AVAudioFormat` directly.

The file should start with:

```swift
import AVFAudio
import Foundation

// MARK: - Crit Mode State
...
```

**Step 3: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 4: Relaunch and verify CritMode still works**

```bash
bash scripts/relaunch.sh
```

**Step 5: Commit**

```
feat: extract AudioCaptureEngine to its own file for reuse
```

---

### Task 2: TranscriptionEngine protocol + SpeechAnalyzerEngine

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/TranscriptionEngine.swift`
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/SpeechAnalyzerEngine.swift`

**Step 1: Create TranscriptionEngine protocol**

```swift
import AVFAudio
import Foundation

/// Protocol for swappable transcription backends.
/// Default implementation: SpeechAnalyzerEngine (macOS 26+).
/// Future: WhisperKitEngine.
@available(macOS 26, *)
protocol TranscriptionEngine: Sendable {
    /// Warm up the engine (model loading, asset checks, resource allocation).
    /// May trigger model downloads on first use.
    func prepare() async throws

    /// Transcribe recorded audio buffers into a single text string.
    /// - Parameters:
    ///   - buffers: Array of recorded AVAudioPCMBuffers from AudioCaptureEngine
    ///   - inputFormat: The audio format of the recorded buffers
    /// - Returns: The transcribed text
    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String
}
```

**Step 2: Create SpeechAnalyzerEngine**

This extracts the transcription logic from CritModeService into a reusable engine. The key difference from CritMode: this returns a single joined string (no segmentation).

```swift
import AVFAudio
import Foundation
import Speech

@available(macOS 26, *)
final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {

    func prepare() async throws {
        // Check mic permission
        let permission = AVAudioApplication.shared.recordPermission
        if permission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                throw SpeechAnalyzerEngineError.microphonePermissionDenied
            }
        }
    }

    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Collect results
        let resultsTask = Task { [transcriber] in
            var segments: [String] = []
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal && !text.isEmpty {
                        segments.append(text)
                    }
                }
            } catch {
                await MainActor.run {
                    debugLog("SpeechAnalyzerEngine: Results error: \(error)")
                }
            }
            return segments
        }

        // Feed buffers
        let yieldedCount = feedBuffers(
            buffers: buffers,
            inputFormat: inputFormat,
            analyzerFormat: analyzerFormat,
            continuation: inputContinuation
        )
        debugLog("SpeechAnalyzerEngine: Yielded \(yieldedCount) buffers")

        // Run analyzer
        try await analyzer.start(inputSequence: inputStream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        // Collect
        let segments = try await resultsTask.value
        return segments.joined(separator: " ")
    }

    // MARK: - Buffer Feeding

    private func feedBuffers(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat?,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Int {
        guard let analyzerFormat else {
            continuation.finish()
            return 0
        }

        let needsConversion = inputFormat != analyzerFormat
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: inputFormat, to: analyzerFormat)
            : nil

        var yielded = 0
        for buffer in buffers {
            if let converter {
                let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
                let scaledLength = Double(buffer.frameLength) * sampleRateRatio
                let frameCapacity = AVAudioFrameCount(scaledLength.rounded(.up))
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: analyzerFormat,
                    frameCapacity: frameCapacity
                ) else { continue }

                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    continuation.yield(AnalyzerInput(buffer: convertedBuffer))
                    yielded += 1
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                yielded += 1
            }
        }

        continuation.finish()
        return yielded
    }
}

enum SpeechAnalyzerEngineError: Error {
    case microphonePermissionDenied
}
```

**Step 3: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
feat: add TranscriptionEngine protocol and SpeechAnalyzerEngine
```

---

### Task 3: VoiceInputService

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/VoiceInputService.swift`

**Step 1: Create VoiceInputService**

```swift
import AVFAudio
import Foundation

@available(macOS 26, *)
enum VoiceInputState: Equatable {
    case idle
    case warmingUp
    case recording
    case processing
}

@available(macOS 26, *)
@MainActor
final class VoiceInputService: ObservableObject {
    static let shared = VoiceInputService()

    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var audioLevels: [Float] = []

    private var captureEngine: AudioCaptureEngine?
    private var recordedBuffers: [AVAudioPCMBuffer] = []
    private var savedInputFormat: AVAudioFormat?
    private var drainTimer: Timer?
    private let transcriptionEngine: TranscriptionEngine = SpeechAnalyzerEngine()
    private let maxLevelCount = 64

    // MARK: - Start Recording

    func startRecording() async throws {
        guard state == .idle else { return }

        state = .warmingUp
        audioLevels = []
        recordedBuffers = []

        do {
            try await transcriptionEngine.prepare()
        } catch {
            state = .idle
            throw error
        }

        let engine = captureEngine ?? AudioCaptureEngine()
        try await Task.detached {
            try engine.start()
        }.value

        self.captureEngine = engine
        startDrainTimer()
        state = .recording
        debugLog("VoiceInputService: Recording started")
    }

    // MARK: - Stop Recording

    /// Stops recording, transcribes, and returns the text.
    func stopRecording() async throws -> String {
        guard state == .recording else { return "" }

        stopAudioCapture()
        state = .processing
        debugLog("VoiceInputService: Recording stopped, processing \(recordedBuffers.count) buffers")

        guard let inputFormat = savedInputFormat else {
            debugLog("VoiceInputService: No input format saved")
            state = .idle
            return ""
        }

        do {
            let text = try await transcriptionEngine.transcribe(
                buffers: recordedBuffers,
                inputFormat: inputFormat
            )
            debugLog("VoiceInputService: Transcribed: \(text.prefix(100))")
            state = .idle
            recordedBuffers = []
            return text
        } catch {
            debugLog("VoiceInputService: Transcription error: \(error)")
            state = .idle
            recordedBuffers = []
            throw error
        }
    }

    // MARK: - Cancel

    func cancelRecording() {
        stopAudioCapture()
        recordedBuffers = []
        audioLevels = []
        state = .idle
        debugLog("VoiceInputService: Recording cancelled")
    }

    // MARK: - Audio Capture Helpers

    private func stopAudioCapture() {
        drainTimer?.invalidate()
        drainTimer = nil
        savedInputFormat = captureEngine?.inputFormat
        if let engine = captureEngine {
            let pending = engine.drain()
            for (_, buffer) in pending {
                recordedBuffers.append(buffer)
            }
            engine.stop()
        }
    }

    private func startDrainTimer() {
        drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainCollector()
            }
        }
    }

    private func drainCollector() {
        guard let engine = captureEngine else { return }
        let pending = engine.drain()
        for (rms, buffer) in pending {
            audioLevels.append(rms)
            if audioLevels.count > maxLevelCount {
                audioLevels.removeFirst(audioLevels.count - maxLevelCount)
            }
            recordedBuffers.append(buffer)
        }
    }
}
```

**Step 2: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add VoiceInputService for voice-to-text recording
```

---

### Task 4: Global shortcut with press-and-hold / double-press detection

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift` (lines 4-17 for shortcut name, lines 26-43 for registration, add new handler)
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift` (line ~127 to add recorder row)

**Step 1: Add voice input shortcut name**

In `GlobalHotkey.swift`, add to the `KeyboardShortcuts.Name` extension (after line 16):

```swift
    static let voiceInput = Self(
        "voiceInput",
        default: .init(.v, modifiers: [.command, .shift])
    )
```

**Step 2: Add voice input handler with hold/tap detection**

Add state tracking properties and the handler to `GlobalHotkey` class. Add after line 23 (after `private init() {}`):

```swift
    private var voiceKeyDownTime: Date?
    private let holdThreshold: TimeInterval = 0.4
```

In `register()` (after the pasteAllComments registration, before the debugLog), add:

```swift
        KeyboardShortcuts.onKeyDown(for: .voiceInput) { [weak self] in
            Task { @MainActor in
                self?.handleVoiceInputKeyDown()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .voiceInput) { [weak self] in
            Task { @MainActor in
                self?.handleVoiceInputKeyUp()
            }
        }
```

In `unregister()`, add `KeyboardShortcuts.disable(.voiceInput)` to the list.

Add the handler methods (after `handlePasteAllHotkey()`):

```swift
    @available(macOS 26, *)
    private func handleVoiceInputKeyDown() {
        debugLog("GlobalHotkey: voiceInput keyDown")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring voice input")
            return
        }

        let voiceService = VoiceInputService.shared
        if voiceService.state == .recording {
            // Already recording — stop (double-press or toggle)
            Task {
                let text = try? await voiceService.stopRecording()
                if let text, !text.isEmpty {
                    CommentInputController.shared.appendVoiceText(text)
                }
            }
            return
        }

        voiceKeyDownTime = Date()

        // Open comment panel if not already visible
        if !CommentInputController.shared.isVisible {
            if let selection = SelectionMonitor.shared.readCurrentSelection() {
                CommentInputController.shared.showForSelection(selection)
            } else {
                CommentInputController.shared.showStandaloneNote()
            }
        }

        // Start recording
        Task {
            do {
                try await voiceService.startRecording()
            } catch {
                debugLog("GlobalHotkey: voice recording failed: \(error)")
                ToastManager.shared.show("Microphone access required")
            }
        }
    }

    @available(macOS 26, *)
    private func handleVoiceInputKeyUp() {
        debugLog("GlobalHotkey: voiceInput keyUp")
        guard let keyDownTime = voiceKeyDownTime else { return }
        voiceKeyDownTime = nil

        let holdDuration = Date().timeIntervalSince(keyDownTime)
        let voiceService = VoiceInputService.shared

        if voiceService.state == .recording && holdDuration > holdThreshold {
            // Was a hold — stop recording on release
            Task {
                let text = try? await voiceService.stopRecording()
                if let text, !text.isEmpty {
                    CommentInputController.shared.appendVoiceText(text)
                }
            }
        }
        // If holdDuration <= threshold, it was a tap — recording continues
        // until next keyDown (handled in handleVoiceInputKeyDown)
    }
```

**Step 3: Add `appendVoiceText` to CommentInputController**

In `CommentInputWindowController.swift`, add a published property for voice text and a method to `CommentInputController` (after `currentAttachments` around line 24):

```swift
    @Published public var pendingVoiceText: String?
```

Add method (after `showForScreenshot` around line 85):

```swift
    public func appendVoiceText(_ text: String) {
        pendingVoiceText = text
    }
```

**Step 4: Add shortcut recorder to Preferences**

In `PreferencesWindowController.swift`, add after the "Paste All" row (after line 127):

```swift
                    settingsRow("Voice Input") {
                        KeyboardShortcuts.Recorder("", name: .voiceInput)
                    }
```

**Step 5: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 6: Relaunch**

```bash
bash scripts/relaunch.sh
```

**Step 7: Commit**

```
feat: add voice input global shortcut with hold/tap detection
```

---

### Task 5: MiniWaveformView for save button

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/MiniWaveformView.swift`

**Step 1: Create MiniWaveformView**

A compact waveform that fits inside the save button area (~28-32pt). Shows 5-7 bars reactive to audio levels. On hover, morphs into a stop icon.

```swift
import SwiftUI

@available(macOS 26, *)
struct MiniWaveformView: View {
    let levels: [Float]
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        ZStack {
            // Stop icon (visible on hover)
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 10, height: 10)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)

            // Waveform bars (hidden on hover)
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let level = sampleLevel(at: index)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(.white)
                        .frame(width: barWidth, height: barHeight(for: level))
                }
            }
            .opacity(isHovered ? 0 : 1)
            .scaleEffect(isHovered ? 0.7 : 1)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func sampleLevel(at index: Int) -> Float {
        guard !levels.isEmpty else { return 0 }
        let recentLevels = Array(levels.suffix(barCount))
        if index < recentLevels.count {
            return recentLevels[index]
        }
        return 0
    }

    private func barHeight(for level: Float) -> CGFloat {
        let maxHeight: CGFloat = 16
        let minHeight: CGFloat = 4
        let scaled = min(max(CGFloat(level) * 16, 0.0), 1.0)
        let normalized = max(pow(scaled, 0.6), 0.05)
        return max(normalized * maxHeight, minHeight)
    }
}
```

**Step 2: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: add MiniWaveformView for voice input save button
```

---

### Task 6: CommentInputView recording UI

This is the largest task — adds the mic button, recording state transformation of the save button, window border accent, and processing indicator. Also wires up voice text appending.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

**Step 1: Add VoiceInputService observation to CommentInputView**

At the top of `CommentInputView`, add state tracking (after the existing `@State` properties around line 13):

```swift
    @State private var isMicHovered = false
    @State private var isWaveformHovered = false
    @ObservedObject private var voiceInput = VoiceInputService.shared
```

Note: `VoiceInputService.shared` requires `@available(macOS 26, *)`. Since the whole app requires macOS 26 for CritMode, check if `CommentInputView` already has this availability annotation. If not, the `@ObservedObject` may need conditional compilation or the view needs the annotation. Look at how CritMode views handle this — they use `@available(macOS 26, *)` on the struct.

If `CommentInputView` does NOT have `@available(macOS 26, *)`, wrap the voice-related properties and UI in availability checks, or add the annotation to the struct. Follow the pattern used by other views in the codebase.

**Step 2: Replace the save button with a conditional view**

Replace the save button `Button(action:)` block (lines 63-83) with a conditional that shows:
- Normal save button when `voiceInput.state == .idle`
- Spinner when `voiceInput.state == .warmingUp`
- MiniWaveformView when `voiceInput.state == .recording`
- Normal save button when `voiceInput.state == .processing`

```swift
                // Save / Recording button
                if voiceInput.state == .warmingUp {
                    // Warming up — spinner in button shape
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Color.remarcBrandGradient(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                } else if voiceInput.state == .recording {
                    // Recording — waveform that becomes stop on hover
                    Button(action: {
                        Task {
                            let text = try? await voiceInput.stopRecording()
                            if let text, !text.isEmpty {
                                appendTranscribedText(text)
                            }
                        }
                    }) {
                        MiniWaveformView(
                            levels: voiceInput.audioLevels,
                            isHovered: isWaveformHovered
                        )
                        .frame(width: 50, height: 20)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Color.red.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isWaveformHovered = hovering }
                    .help("Stop recording")
                } else {
                    // Idle or processing — normal save button
                    Button(action: { controller.saveComment(text: commentText, attachments: attachments) }) {
                        HStack(spacing: 6) {
                            Text("Save")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌘↵")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Color.remarcBrandGradient(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .opacity(isSaveHovered ? 1.0 : 0.85)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isSaveHovered = hovering }
                    .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
                    .accessibilityIdentifier("remarc.commentInput.submitButton")
                }
```

**Step 3: Add mic button to footer**

Add a mic button between the attachment button and Spacer in the footer HStack (after line 59, before `Spacer()`):

```swift
                Button(action: {
                    if voiceInput.state == .recording {
                        Task {
                            let text = try? await voiceInput.stopRecording()
                            if let text, !text.isEmpty {
                                appendTranscribedText(text)
                            }
                        }
                    } else if voiceInput.state == .idle {
                        Task {
                            do {
                                try await voiceInput.startRecording()
                            } catch {
                                ToastManager.shared.show("Microphone access required")
                            }
                        }
                    }
                }) {
                    Image(systemName: voiceInput.state == .recording ? "mic.fill" : "mic")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            voiceInput.state == .recording
                                ? Color.red
                                : .primary.opacity(isMicHovered ? 0.6 : 0.3)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in isMicHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isMicHovered)
                .help(voiceInput.state == .recording ? "Stop recording" : "Voice input")
                .disabled(voiceInput.state == .warmingUp || voiceInput.state == .processing)
```

**Step 4: Add processing indicator in text area**

Add after the `CommentTextEditor` block (after line 45), conditionally when processing:

```swift
            if voiceInput.state == .processing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Transcribing...")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: commentText.isEmpty ? .center : .leading)
            }
```

**Step 5: Add window border accent overlay**

Wrap the outer `VStack` (or add an overlay) that shows when recording. Add an overlay to the outermost container inside `body`:

On the `VStack(spacing: 0)` (line 19), add an overlay:

```swift
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.remarcPrimary(for: colorScheme).opacity(0.6), lineWidth: 1.5)
                .opacity(voiceInput.state == .warmingUp || voiceInput.state == .recording ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: voiceInput.state)
        )
```

Note: The overlay must be applied carefully — it should be on the SwiftUI content root, inside the VEV, so it follows the panel's rounded shape. Check how the comment input panel's corner radius is set and match it.

**Step 6: Add voice text appending helper and onChange handler**

Add a helper method to `CommentInputView`:

```swift
    private func appendTranscribedText(_ text: String) {
        if commentText.isEmpty {
            commentText = text
        } else {
            commentText += " " + text
        }
    }
```

Add an `onChange` handler for `controller.pendingVoiceText` (near the other onChange handlers around line 119):

```swift
        .onChange(of: controller.pendingVoiceText) {
            if let text = controller.pendingVoiceText, !text.isEmpty {
                appendTranscribedText(text)
                controller.pendingVoiceText = nil
            }
        }
```

**Step 7: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 8: Relaunch and test manually**

```bash
bash scripts/relaunch.sh
```

Test checklist:
- Open a comment box (Cmd+Shift+C with/without selection)
- Verify mic button appears in footer next to paperclip
- Click mic button — verify warming up spinner, then waveform in save button area
- Speak — verify waveform bars react
- Hover waveform button — verify stop icon appears
- Click stop — verify processing indicator, then text appears
- Verify accent border appears during recording
- Try the global shortcut (Cmd+Shift+V) — verify panel opens and recording starts

**Step 9: Commit**

```
feat: add voice input UI to comment box — mic button, waveform save button, recording states
```

---

### Task 7: Wire up CommentInputView cancellation and edge cases

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

**Step 1: Cancel recording on dismiss**

In `CommentInputController.dismiss()` (in CommentInputWindowController.swift), add voice cancellation before the panel teardown:

```swift
        // Cancel any active voice recording
        if #available(macOS 26, *) {
            VoiceInputService.shared.cancelRecording()
        }
```

Find the `dismiss()` method and add this near the top, before the panel fade-out animation.

**Step 2: Cancel recording on text reset**

In `CommentInputView`, in the `onChange(of: controller.textResetToken)` handler (around line 111), add:

```swift
            if voiceInput.state != .idle {
                voiceInput.cancelRecording()
            }
```

**Step 3: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 4: Relaunch and test**

```bash
bash scripts/relaunch.sh
```

Test: Start voice recording, then dismiss the panel (click outside or press Escape). Verify recording stops cleanly.

**Step 5: Commit**

```
feat: cancel voice recording on panel dismiss and text reset
```

---

### Task 8: Final integration testing and polish

**Files:**
- Possibly adjust: any file from previous tasks based on testing

**Step 1: Full flow manual testing**

Test all flows end-to-end:

1. **Hold shortcut (Cmd+Shift+V)**: Hold key → panel opens → recording starts → release key → recording stops → text appears → edit → save
2. **Tap shortcut twice**: Tap key → panel opens → recording starts → tap key again → recording stops → text appears
3. **Mic button in existing comment**: Open comment with Cmd+Shift+C → type some text → click mic → speak → stop → verify text is appended
4. **No selection + shortcut**: Press Cmd+Shift+V without selecting text → verify quick note panel opens
5. **With selection + shortcut**: Select text in any app → press Cmd+Shift+V → verify comment panel with selection reference opens
6. **Escape during recording**: Start recording → press Escape → verify recording cancels and panel dismisses
7. **Remap to single key**: Open Preferences → remap Voice Input to a function key → verify it works

**Step 2: Fix any issues found during testing**

Address any bugs or polish items found.

**Step 3: Relaunch**

```bash
bash scripts/relaunch.sh
```

**Step 4: Commit**

```
fix: voice input integration polish
```

(Only if changes were needed)
