import AVFAudio
import Foundation
import Speech

@available(macOS 26, *)
final class SpeechAnalyzerEngine: TranscriptionEngine, Sendable {

    func prepare() async throws {
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
        let segments = try await transcribeSegments(buffers: buffers, inputFormat: inputFormat)
        return segments.joined(separator: " ")
    }

    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String] {
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

        // Collect results — each isFinal result is a natural speech segment
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
        return try await resultsTask.value
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
