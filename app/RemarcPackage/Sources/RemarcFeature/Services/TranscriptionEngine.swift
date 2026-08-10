import AVFAudio
import Foundation

/// Protocol for swappable transcription backends.
@available(macOS 26, *)
protocol TranscriptionEngine: Sendable {
    /// Warm up the engine (model loading, asset checks, resource allocation).
    /// May trigger model downloads on first use.
    func prepare() async throws

    /// Transcribe recorded audio buffers into a single text string.
    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String

    /// Transcribe into individual speech segments (for Crit Mode).
    /// Default implementation returns the full transcription as a single segment.
    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String]
}

@available(macOS 26, *)
extension TranscriptionEngine {
    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String] {
        let text = try await transcribe(buffers: buffers, inputFormat: inputFormat)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }
}
