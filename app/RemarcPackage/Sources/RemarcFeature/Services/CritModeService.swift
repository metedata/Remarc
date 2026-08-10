import AVFAudio
import Foundation

// MARK: - Crit Mode State

enum CritModeState: Equatable {
    case idle
    case preparingModel
    case recording(startTime: Date)
    case processing

    static func == (lhs: CritModeState, rhs: CritModeState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparingModel, .preparingModel), (.processing, .processing):
            return true
        case (.recording(let a), .recording(let b)):
            return a == b
        default:
            return false
        }
    }
}

enum CritModeError: Error {
    case microphonePermissionDenied
}

enum CritModeTextNormalizer {
    static func sentenceCaseIfAllCaps(_ text: String) -> String {
        let casedCharacters = text.filter { $0.isUppercase || $0.isLowercase }
        guard !casedCharacters.isEmpty,
              casedCharacters.allSatisfy(\.isUppercase) else {
            return text
        }

        var normalized = text.lowercased()
        guard let firstLetter = normalized.firstIndex(where: \.isLetter) else {
            return text
        }

        let end = normalized.index(after: firstLetter)
        normalized.replaceSubrange(
            firstLetter..<end,
            with: normalized[firstLetter..<end].uppercased()
        )
        return normalized
    }
}

// MARK: - CritModeService

@available(macOS 26, *)
@MainActor
final class CritModeService: ObservableObject {
    static let shared = CritModeService()

    @Published var state: CritModeState = .idle
    @Published var audioLevels: [Float] = []
    @Published var smoothedLevel: Float = 0
    @Published var slowSmoothedLevel: Float = 0

    private var captureEngine: AudioCaptureEngine?
    private var recordedBuffers: [AVAudioPCMBuffer] = []
    private var savedInputFormat: AVAudioFormat?
    private var drainTimer: Timer?

    private let maxLevelCount = 128
    private var deferredMuteTask: Task<Void, Never>?

    // MARK: - Start Recording

    func startRecording() async throws {
        guard state == .idle else { return }

        // Mutual exclusion: cancel dictation if active
        DictationService.shared.cancelRecording()

        deferredMuteTask = DictationSounds.playStartAndDeferMute()

        state = .preparingModel
        try await prepareModelsIfNeeded()

        resetAudioState()

        // Reuse existing capture engine or create one. Reusing avoids the
        // macOS bug where a second AVAudioEngine's tap silently stops firing.
        // The engine's installTap closure must not be defined in a @MainActor
        // context, otherwise Swift 6 inserts isolation checks that crash on
        // the realtime audio thread.
        let engine = captureEngine ?? AudioCaptureEngine()
        let smartMicrophoneSelection = SettingsManager.shared.smartMicrophoneSelection
        try await Task.detached {
            try engine.start(smartMicrophoneSelection: smartMicrophoneSelection)
        }.value

        self.captureEngine = engine
        startDrainTimer()

        state = .recording(startTime: Date())
        debugLog("CritModeService: Recording started")
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> [Comment] {
        guard case .recording = state else { return [] }

        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        state = .processing

        debugLog("CritModeService: Recording stopped, processing \(recordedBuffers.count) buffers")

        // Silence gate: skip transcription if peak RMS is below threshold.
        // Whisper hallucinates on silent audio (known issue), which then gets
        // amplified by Foundation Models fabricating multiple "feedback" items.
        let peakRMS = audioLevels.max() ?? 0
        guard peakRMS > 0.01 else {
            debugLog("CritModeService: Silent recording (peakRMS=\(peakRMS)), skipping transcription")
            DictationSounds.playStop()
            state = .idle
            return []
        }

        // Run transcription - returns individual final results as segments
        let rawSegments = try await transcribe()
        debugLog("CritModeService: Raw transcript: \(rawSegments)")
        let transcriptSegments = rawSegments.compactMap { Self.meaningfulTranscript($0) }
        guard !transcriptSegments.isEmpty else {
            debugLog("CritModeService: No meaningful transcript (raw=\(rawSegments))")
            DictationSounds.playStop()
            state = .idle
            return []
        }

        debugLog("CritModeService: Got \(transcriptSegments.count) transcript segments: \(transcriptSegments)")

        // Only invoke Foundation Models when there's enough content to plausibly
        // contain multiple critique points. Short transcripts are almost always
        // Whisper non-speech narrations that slipped past the filter, or a single
        // point that doesn't need splitting. FM on tiny inputs also triggers a
        // context-overflow error on this OS build.
        let fullTranscript = transcriptSegments.joined(separator: " ")
        let totalWords = fullTranscript.split { $0.isWhitespace }.count
        let segments: [String]
        if totalWords < 10 {
            debugLog("CritModeService: Transcript too short for FM segmentation (\(totalWords) words), using speech segments")
            segments = transcriptSegments
        } else {
            segments = await segment(transcript: fullTranscript, speechSegments: transcriptSegments)
        }

        // If the user cancelled during processing, drop the result.
        guard case .processing = state else {
            debugLog("CritModeService: State is \(state), discarding post-cancel results")
            return []
        }

        // Normalize every output path, including short transcripts and
        // Foundation Models fallbacks that bypass generated segmentation.
        let normalizedSegments = segments.map(
            CritModeTextNormalizer.sentenceCaseIfAllCaps
        )

        // Create comments
        let comments = createComments(from: normalizedSegments)
        debugLog("CritModeService: Created \(comments.count) comments")

        DictationSounds.playStop()
        state = .idle
        return comments
    }

    // MARK: - Cancel

    func cancelRecording() {
        deferredMuteTask?.cancel()
        stopAudioCapture()
        MediaRemoteController.shared.resumeIfWePaused()
        resetAudioState()
        state = .idle
        debugLog("CritModeService: Recording cancelled")
    }

    private func resetAudioState() {
        recordedBuffers = []
        audioLevels = []
        smoothedLevel = 0
        slowSmoothedLevel = 0
    }

    // MARK: - Audio Capture Helpers

    private func stopAudioCapture() {
        drainTimer?.invalidate()
        drainTimer = nil
        // Save the input format before stopping — needed for transcription
        savedInputFormat = captureEngine?.inputFormat
        // Drain any remaining data from the collector
        if let engine = captureEngine {
            let pending = engine.stopAndDrain()
            for (rms, buffer) in pending {
                appendLevel(rms)
                recordedBuffers.append(buffer)
            }
        }
        // Keep captureEngine alive — reused for next recording
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
        var latestRMS: Float = 0
        for (rms, buffer) in pending {
            appendLevel(rms)
            recordedBuffers.append(buffer)
            latestRMS = rms
        }
        // Smooth audio levels for visual effects
        if !pending.isEmpty {
            smoothedLevel = smoothedLevel * 0.85 + latestRMS * 0.15
            slowSmoothedLevel = slowSmoothedLevel * 0.95 + latestRMS * 0.05
        }
    }

    // MARK: - Audio Levels

    private func appendLevel(_ rms: Float) {
        audioLevels.append(rms)
        // Truncate periodically instead of O(n) removeFirst on every sample
        if audioLevels.count > maxLevelCount * 2 {
            audioLevels = Array(audioLevels.suffix(maxLevelCount))
        }
    }

    // MARK: - Transcription

    private func transcribe() async throws -> [String] {
        guard let inputFormat = savedInputFormat else {
            debugLog("CritModeService: No input format saved")
            return []
        }

        let engine = TranscriptionEngineFactory.createEngine()
        do {
            try await engine.prepare()
        } catch {
            debugLog("CritModeService: Engine prepare failed, falling back to Apple Speech: \(error)")
            return try await _transcribeWithSpeechAnalyzer()
        }

        // Safe: captured before await; cancelRecording() sets state=.idle
        // which prevents re-entry into stopRecording().
        nonisolated(unsafe) let buffersSnapshot = recordedBuffers
        nonisolated(unsafe) let formatSnapshot = inputFormat
        let segments = try await engine.transcribeSegments(
            buffers: buffersSnapshot,
            inputFormat: formatSnapshot
        )

        if segments.isEmpty {
            debugLog("CritModeService: Engine returned empty, falling back to Apple Speech")
            return try await _transcribeWithSpeechAnalyzer()
        }
        return segments
    }

    private func _transcribeWithSpeechAnalyzer() async throws -> [String] {
        let transcriber = await _createTranscriber()
        let analyzer = await _createAnalyzer(transcriber: transcriber)
        let analyzerFormat = await _getAnalyzerFormat(transcriber: transcriber)

        debugLog("CritModeService: Analyzer format: \(String(describing: analyzerFormat))")
        debugLog("CritModeService: Input format: \(String(describing: savedInputFormat))")

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Pattern from Apple docs: three concurrent operations.
        // 1. A Task to consume transcriber.results
        // 2. analyzer.start() to consume the input stream (blocks until stream ends)
        // 3. Feed buffers into the stream

        // Step 1: Start a separate Task to collect results (must run concurrently)
        // Each isFinal result is a natural speech segment — collect them all.
        debugLog("CritModeService: Starting results collector task")
        let resultsTask = Task { [transcriber] in
            var segments: [String] = []
            var resultCount = 0
            do {
                for try await result in transcriber.results {
                    resultCount += 1
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        debugLog("CritModeService: Result #\(resultCount) isFinal=\(result.isFinal) text=\(text.prefix(100))")
                    }
                    if result.isFinal && !text.isEmpty {
                        segments.append(text)
                    }
                }
                await MainActor.run {
                    debugLog("CritModeService: Results stream ended, \(resultCount) results, \(segments.count) segments")
                }
            } catch {
                await MainActor.run {
                    debugLog("CritModeService: Results error: \(error)")
                }
            }
            return segments
        }

        // Step 2: Feed all recorded buffers into the stream, then finish it
        debugLog("CritModeService: Feeding \(recordedBuffers.count) buffers")
        let yieldedCount = _feedBuffersDirect(
            inputContinuation: inputContinuation,
            analyzerFormat: analyzerFormat
        )
        debugLog("CritModeService: Actually yielded \(yieldedCount) buffers, stream finished")

        // Step 3: Start analyzer — blocks until input stream ends (already finished)
        debugLog("CritModeService: Starting analyzer.start()")
        try await analyzer.start(inputSequence: inputStream)
        debugLog("CritModeService: analyzer.start() returned")

        // Step 4: Finalize — signals transcriber.results to terminate
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        debugLog("CritModeService: Finalized analyzer")

        // Step 5: Collect segments from the task
        let segments = try await resultsTask.value
        debugLog("CritModeService: Got \(segments.count) final segments")

        return segments
    }

    // These methods are implemented in the SpeechAnalyzer extension below
    // to keep the Speech import isolated

    // MARK: - Segmentation

    private func segment(transcript: String, speechSegments: [String]) async -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return await _segmentWithFoundationModels(transcript: transcript, speechSegments: speechSegments)
        }
        #endif
        return speechSegments
    }

    // MARK: - Transcript Filtering

    // Whisper hallucinates non-speech sounds as stage-direction text and emits
    // well-known YouTube-style outros on silence. Exact match after lowercasing
    // and trimming punctuation.
    private static let knownWhisperHallucinations: Set<String> = [
        "clears throat", "coughs", "sighs", "laughs", "laughter", "breathes",
        "thank you", "thanks", "thanks for watching", "thank you for watching",
        "thanks for watching the video", "thanks for watching everyone",
        "please subscribe", "subscribe to my channel", "like and subscribe",
        "don't forget to subscribe", "don't forget to like and subscribe",
        "see you in the next video", "see you next time", "see you",
        "bye", "goodbye", "okay", "ok", "hmm", "uh", "um", "mm", "uh huh",
        "mhm", "you", "the", "a", "yeah", "yep", "right"
    ]

    fileprivate static func meaningfulTranscript(_ text: String) -> String? {
        // Strip bracketed/parenthetical/asterisk stage directions
        let cleaned = text
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^\)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*[^\*]*\*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let normalized = cleaned
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if knownWhisperHallucinations.contains(normalized) { return nil }

        // Require at least 3 words - shorter outputs are almost always
        // Whisper misfires on breath/noise rather than real feedback.
        let words = cleaned.split { $0.isWhitespace }
        guard words.count >= 3 else { return nil }

        return cleaned
    }

    // MARK: - Comment Creation

    private func createComments(from segments: [String]) -> [Comment] {
        var created: [Comment] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let comment = PersistenceManager.shared.createComment(
                type: .critMode,
                commentText: trimmed,
                source: "Crit Mode",
                appBundleID: nil
            ) {
                created.append(comment)
            }
        }
        return created
    }

    // MARK: - Model Preparation

    private func prepareModelsIfNeeded() async throws {
        // Request mic permission on the MainActor BEFORE starting the engine.
        // The engine starts in Task.detached — if TCC hasn't been granted yet,
        // the permission dialog may not appear from a background thread (especially
        // for LSUIElement menu bar apps). Requesting here ensures the dialog shows.
        let permission = AVAudioApplication.shared.recordPermission
        debugLog("CritModeService: Mic permission status: \(permission.rawValue)")
        if permission != .granted {
            let granted = await AVAudioApplication.requestRecordPermission()
            debugLog("CritModeService: Mic permission request result: \(granted)")
            if !granted {
                debugLog("CritModeService: Mic permission denied")
                throw CritModeError.microphonePermissionDenied
            }
        }

        // Ensure minimum display time so R logo traces and fills before recording starts
        try await Task.sleep(for: .seconds(2.5))
    }
}

// MARK: - SpeechAnalyzer Integration

import Speech

@available(macOS 26, *)
extension CritModeService {

    fileprivate func _createTranscriber() async -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    fileprivate func _createAnalyzer(transcriber: SpeechTranscriber) async -> SpeechAnalyzer {
        SpeechAnalyzer(modules: [transcriber])
    }

    fileprivate func _getAnalyzerFormat(transcriber: SpeechTranscriber) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    fileprivate func _feedBuffersDirect(inputContinuation: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat?) -> Int {
        guard let inputFormat = self.savedInputFormat, let analyzerFormat else {
            debugLog("CritModeService: _feedBuffers — no input format or analyzer format, finishing empty")
            inputContinuation.finish()
            return 0
        }

        debugLog("CritModeService: Input format: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch")
        debugLog("CritModeService: Analyzer format: \(analyzerFormat.sampleRate)Hz \(analyzerFormat.channelCount)ch")

        let needsConversion = inputFormat != analyzerFormat
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: inputFormat, to: analyzerFormat)
            : nil

        if needsConversion {
            debugLog("CritModeService: Format conversion needed (converter: \(converter != nil ? "created" : "FAILED"))")
        }

        var yielded = 0
        var convertErrors = 0

        for buffer in recordedBuffers {
            if let converter = converter {
                let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
                let scaledLength = Double(buffer.frameLength) * sampleRateRatio
                let frameCapacity = AVAudioFrameCount(scaledLength.rounded(.up))
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: analyzerFormat,
                    frameCapacity: frameCapacity
                ) else { continue }

                var error: NSError?
                nonisolated(unsafe) var consumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if let error = error {
                    convertErrors += 1
                    if convertErrors <= 3 {
                        debugLog("CritModeService: Convert error: \(error.localizedDescription)")
                    }
                } else {
                    inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
                    yielded += 1
                }
            } else {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
                yielded += 1
            }
        }

        if convertErrors > 0 {
            debugLog("CritModeService: \(convertErrors) conversion errors total")
        }

        inputContinuation.finish()
        recordedBuffers = []
        return yielded
    }
}

// MARK: - Foundation Models Integration

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
@Generable
struct CritiqueSegments {
    @Guide(description: "Array of distinct feedback points. Each should be a single, self-contained observation or suggestion in ordinary sentence case, never all caps, with filler words (um, uh, like, you know, so, basically, I mean) removed.")
    var segments: [String]
}

@available(macOS 26, *)
extension CritModeService {

    fileprivate func _segmentWithFoundationModels(transcript: String, speechSegments: [String]) async -> [String] {
        guard SystemLanguageModel.default.isAvailable else {
            debugLog("CritModeService: Foundation Models not available, using \(speechSegments.count) speech segments")
            return speechSegments
        }

        do {
            let session = LanguageModelSession(instructions: """
                Segment this critique transcript into distinct feedback points.
                Each segment should be one self-contained observation, suggestion, or critique.
                Clean up each segment so it reads as a standalone comment:
                - Remove filler words (um, uh, like, you know, so, basically, I mean)
                - Use ordinary sentence case for each segment; never use ALL CAPS
                - Keep the speaker's intent and meaning — do not rephrase or editorialize
                Return each as a separate item in the segments array.
                """)

            let response = try await session.respond(
                to: transcript,
                generating: CritiqueSegments.self
            )
            let segments = response.content.segments
            guard !segments.isEmpty else {
                return fallbackSegment(transcript: transcript)
            }
            return segments
        } catch {
            debugLog("CritModeService: Foundation Models segmentation failed: \(error), using speech segments")
            return speechSegments
        }
    }

    private func fallbackSegment(transcript: String) -> [String] {
        // Split on double newlines or sentence boundaries for reasonable chunks
        let paragraphs = transcript.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count > 1 {
            return paragraphs
        }

        // Single block — return as one comment
        return [transcript]
    }
}
#endif
