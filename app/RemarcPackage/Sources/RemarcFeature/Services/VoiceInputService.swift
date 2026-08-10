import AVFAudio
import Foundation
import SwiftUI

@available(macOS 26, *)
enum VoiceInputState: Equatable {
    case idle
    case warmingUp
    case recording
    case processing
}

@available(macOS 26, *)
enum TranscriptionEngineFactory {
    @MainActor
    static func createEngine() -> any TranscriptionEngine {
        switch SettingsManager.shared.transcriptionEngine {
        case .appleSpeech:
            debugLog("TranscriptionEngineFactory: Using Apple Speech")
            return SpeechAnalyzerEngine()
        case .whisperKit:
            let model = SettingsManager.shared.whisperKitModel
            debugLog("TranscriptionEngineFactory: Using WhisperKit (\(model.rawValue))")
            return WhisperKitEngine(model: model)
        case .parakeet:
            let version = SettingsManager.shared.parakeetModelVersion
            debugLog("TranscriptionEngineFactory: Using Parakeet (\(version.rawValue))")
            return ParakeetEngine(version: version)
        }
    }
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
    /// Engine for the current recording session. Set in startRecording(),
    /// used in stopRecording(). Per-session so settings changes take effect
    /// on the next recording without requiring app restart.
    private var transcriptionEngine: (any TranscriptionEngine)?
    private let maxLevelCount = 64
    private let stateAnimation: Animation = .easeInOut(duration: 0.3)
    private var deferredMuteTask: Task<Void, Never>?

    private func setState(_ newState: VoiceInputState) {
        withAnimation(stateAnimation) { state = newState }
    }

    // MARK: - Start Recording

    func startRecording() async throws {
        guard state == .idle else { return }

        // Mutual exclusion: cancel dictation if active
        DictationService.shared.cancelRecording()

        // Create engine for this session — reads current setting
        transcriptionEngine = TranscriptionEngineFactory.createEngine()

        deferredMuteTask = DictationSounds.playStartAndDeferMute()

        setState(.warmingUp)
        audioLevels = []
        recordedBuffers = []

        do {
            try await transcriptionEngine?.prepare()
        } catch {
            debugLog("VoiceInputService: enginePrepare failed - \(error)")
            transcriptionEngine = nil
            MediaRemoteController.shared.resumeIfWePaused()
            setState(.idle)
            throw error
        }

        let engine = captureEngine ?? AudioCaptureEngine()
        let smartMicrophoneSelection = SettingsManager.shared.smartMicrophoneSelection
        try await Task.detached {
            try engine.start(smartMicrophoneSelection: smartMicrophoneSelection)
        }.value

        self.captureEngine = engine
        startDrainTimer()

        setState(.recording)
        debugLog("VoiceInputService: Recording started")
    }

    // MARK: - Stop Recording

    /// Stops recording, transcribes, and returns the text.
    func stopRecording() async throws -> String {
        guard state == .recording else { return "" }

        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        setState(.processing)
        debugLog("VoiceInputService: Recording stopped, processing \(recordedBuffers.count) buffers")

        guard let engine = transcriptionEngine else {
            debugLog("VoiceInputService: No transcription engine")
            setState(.idle)
            return ""
        }

        guard let inputFormat = savedInputFormat else {
            debugLog("VoiceInputService: No input format saved")
            transcriptionEngine = nil
            setState(.idle)
            return ""
        }

        nonisolated(unsafe) let buffersToTranscribe = recordedBuffers
        nonisolated(unsafe) let format = inputFormat
        do {
            let text = try await engine.transcribe(
                buffers: buffersToTranscribe,
                inputFormat: format
            )
            debugLog("VoiceInputService: Transcribed: \(text.prefix(100))")
            DictationSounds.playStop()
            transcriptionEngine = nil
            setState(.idle)
            recordedBuffers = []
            return text
        } catch {
            debugLog("VoiceInputService: Transcription error: \(error)")
            transcriptionEngine = nil
            setState(.idle)
            recordedBuffers = []
            throw error
        }
    }

    // MARK: - Cancel

    func cancelRecording() {
        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        transcriptionEngine = nil
        recordedBuffers = []
        audioLevels = []
        setState(.idle)
        debugLog("VoiceInputService: Recording cancelled")
    }

    // MARK: - Audio Capture Helpers

    private func stopAudioCapture() {
        drainTimer?.invalidate()
        drainTimer = nil
        savedInputFormat = captureEngine?.inputFormat
        if let engine = captureEngine {
            let pending = engine.stopAndDrain()
            for (_, buffer) in pending {
                recordedBuffers.append(buffer)
            }
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
            recordedBuffers.append(buffer)
        }
        // Truncate periodically instead of O(n) removeFirst on every sample
        if audioLevels.count > maxLevelCount * 2 {
            audioLevels = Array(audioLevels.suffix(maxLevelCount))
        }
    }
}
