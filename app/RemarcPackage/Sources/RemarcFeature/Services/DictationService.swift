import AVFAudio
import Foundation
import SwiftUI

@available(macOS 26, *)
enum DictationState: Equatable {
    case idle
    case warmingUp
    case recording
    case processing
}

@available(macOS 26, *)
@MainActor
final class DictationService: ObservableObject {
    static let shared = DictationService()

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var audioLevels: [Float] = []
    @Published var persistentMode: Bool = false

    private var captureEngine: AudioCaptureEngine?
    private var recordedBuffers: [AVAudioPCMBuffer] = []
    private var savedInputFormat: AVAudioFormat?
    private var drainTimer: Timer?
    private var transcriptionEngine: (any TranscriptionEngine)?
    private let maxLevelCount = 64

    // MARK: - Animation & Minimum Durations

    private let stateAnimation: Animation = .easeInOut(duration: 0.3)
    private let minProcessingDuration: TimeInterval = 0.5
    private var stateEnteredAt: Date = .distantPast
    private var deferredMuteTask: Task<Void, Never>?

    private func setState(_ newState: DictationState) {
        stateEnteredAt = Date()
        withAnimation(stateAnimation) { state = newState }
    }

    private func waitMinimumDuration(_ minimum: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(stateEnteredAt)
        let remaining = minimum - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
        }
    }

    // MARK: - Start Recording

    func startRecording() async throws {
        guard state == .idle else { return }

        // Request mic permission before starting
        let permission = AVAudioApplication.shared.recordPermission
        if permission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                debugLog("DictationService: Mic permission denied")
                throw NSError(domain: "DictationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
            }
        }

        // Mutual exclusion: cancel other audio modes
        VoiceInputService.shared.cancelRecording()
        CritModeService.shared.cancelRecording()

        transcriptionEngine = TranscriptionEngineFactory.createEngine()

        deferredMuteTask = DictationSounds.playStartAndDeferMute()

        setState(.warmingUp)
        audioLevels = []
        recordedBuffers = []

        do {
            try await transcriptionEngine?.prepare()
        } catch {
            debugLog("DictationService: enginePrepare failed - \(error)")
            transcriptionEngine = nil
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
        debugLog("DictationService: Recording started")
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> String {
        guard state == .recording else { return "" }

        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        setState(.processing)
        debugLog("DictationService: Recording stopped, processing \(recordedBuffers.count) buffers")

        guard let engine = transcriptionEngine else {
            debugLog("DictationService: No transcription engine")
            setState(.idle)
            return ""
        }

        guard let inputFormat = savedInputFormat else {
            debugLog("DictationService: No input format saved")
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
            debugLog("DictationService: Transcribed: \(text.prefix(100))")
            await waitMinimumDuration(minProcessingDuration)
            transcriptionEngine = nil
            setState(.idle)
            persistentMode = false
            recordedBuffers = []
            return text
        } catch {
            debugLog("DictationService: Transcription error: \(error)")
            await waitMinimumDuration(minProcessingDuration)
            transcriptionEngine = nil
            setState(.idle)
            persistentMode = false
            recordedBuffers = []
            throw error
        }
    }

    // MARK: - Cancel

    func cancelRecording() {
        guard state != .idle else { return }
        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        transcriptionEngine = nil
        recordedBuffers = []
        audioLevels = []
        persistentMode = false
        setState(.idle)
        debugLog("DictationService: Recording cancelled")
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
        if audioLevels.count > maxLevelCount * 2 {
            audioLevels = Array(audioLevels.suffix(maxLevelCount))
        }
    }
}
