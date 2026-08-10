import Foundation

struct WhisperTranscriptWord: Equatable, Sendable {
    let word: String
    let start: Float
    let end: Float
}

struct WhisperTranscriptSegment: Equatable, Sendable {
    let text: String
    let start: Float
    let end: Float
    let words: [WhisperTranscriptWord]
}

enum WhisperKitTranscriptFormatter {
    private static let sampleRate: Float = 16_000
    private static let analysisWindowDuration: Float = 0.03
    private static let tailGraceDuration: Float = 0.55
    private static let originalAudioGraceDuration: Float = 0.45
    private static let minimumSpeechRMS: Float = 0.002

    static func transcript(
        from segments: [WhisperTranscriptSegment],
        audioSamples: [Float]
    ) -> String {
        segmentTexts(from: segments, audioSamples: audioSamples)
            .joined(separator: " ")
            .cleanedWhisperTranscriptText()
    }

    static func transcript(
        from segments: [WhisperTranscriptSegment],
        speechEndTime: Float
    ) -> String {
        segmentTexts(from: segments, speechEndTime: speechEndTime)
            .joined(separator: " ")
            .cleanedWhisperTranscriptText()
    }

    static func segmentTexts(
        from segments: [WhisperTranscriptSegment],
        audioSamples: [Float]
    ) -> [String] {
        let originalAudioEnd = Float(audioSamples.count) / sampleRate
        let detectedSpeechEnd = detectedSpeechEndTime(in: audioSamples) ?? originalAudioEnd
        let cutoff = min(
            detectedSpeechEnd + tailGraceDuration,
            originalAudioEnd + originalAudioGraceDuration
        )
        let trimmed = segmentTexts(from: segments, tailCutoff: cutoff)
        if !trimmed.isEmpty { return trimmed }

        // Trimming removed every segment. WhisperKit's segment/word timestamps
        // are unreliable for short or padded clips — it can report start times
        // tens of seconds past the real audio — so the cutoff comparison drops
        // everything. Tail trimming may refine a hallucinated tail, but it must
        // never erase a real transcript; fall back to the untrimmed text.
        return segments.compactMap { segment in
            let text = untrimmedText(for: segment).cleanedWhisperTranscriptText()
            return text.isEmpty ? nil : text
        }
    }

    static func segmentTexts(
        from segments: [WhisperTranscriptSegment],
        speechEndTime: Float
    ) -> [String] {
        segmentTexts(from: segments, tailCutoff: speechEndTime + tailGraceDuration)
    }

    static func detectedSpeechEndTime(in samples: [Float]) -> Float? {
        guard !samples.isEmpty else { return nil }

        let windowSize = max(1, Int((analysisWindowDuration * sampleRate).rounded()))
        var windows: [(endSample: Int, rms: Float)] = []
        windows.reserveCapacity((samples.count / windowSize) + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + windowSize, samples.count)
            windows.append((end, rootMeanSquare(samples[index..<end])))
            index = end
        }

        guard let peakRMS = windows.map(\.rms).max(), peakRMS > 0 else {
            return nil
        }

        let sortedRMS = windows.map(\.rms).sorted()
        let noiseFloor = sortedRMS[max(0, sortedRMS.count / 10)]
        let threshold = max(minimumSpeechRMS, noiseFloor * 3, peakRMS * 0.05)
        guard peakRMS > threshold else { return nil }

        guard let lastSpeechWindow = windows.last(where: { $0.rms >= threshold }) else {
            return nil
        }
        return Float(lastSpeechWindow.endSample) / sampleRate
    }

    private static func segmentTexts(
        from segments: [WhisperTranscriptSegment],
        tailCutoff: Float
    ) -> [String] {
        segments.compactMap { segment in
            let text = text(for: segment, tailCutoff: tailCutoff)
                .cleanedWhisperTranscriptText()
            return text.isEmpty ? nil : text
        }
    }

    private static func text(
        for segment: WhisperTranscriptSegment,
        tailCutoff: Float
    ) -> String {
        guard segment.start <= tailCutoff else { return "" }
        guard !segment.words.isEmpty else { return segment.text }

        return segment.words
            .filter { $0.start <= tailCutoff }
            .map(\.word)
            .joined()
    }

    private static func untrimmedText(for segment: WhisperTranscriptSegment) -> String {
        segment.words.isEmpty
            ? segment.text
            : segment.words.map(\.word).joined()
    }

    private static func rootMeanSquare(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}

extension String {
    func cleanedWhisperTranscriptText() -> String {
        replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
