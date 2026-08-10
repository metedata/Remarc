import AVFAudio
import Testing
@testable import RemarcFeature

@Test func placeholder() async throws {
    #expect(true)
}

@Test func audioBufferConverterPreservesSamplesAndPadsTail() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let first = try makeBuffer(samples: [0.1, 0.2], format: format)
    let second = try makeBuffer(samples: [0.3, 0.4], format: format)

    let converted = AudioBufferConverter.convertToFloatArray(
        buffers: [first, second],
        inputFormat: format,
        trailingSilenceDuration: 0.25
    )

    #expect(converted.count == 4 + 4_000)
    #expect(Array(converted.prefix(4)) == [0.1, 0.2, 0.3, 0.4])
    #expect(converted.dropFirst(4).allSatisfy { $0 == 0 })
}

@Test func audioBufferConverterResamplesConcatenatedBuffersWithoutDroppingTail() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let first = try makeRampBuffer(frameCount: 24_000, start: 0, format: format)
    let second = try makeRampBuffer(frameCount: 24_000, start: 24_000, format: format)

    let converted = AudioBufferConverter.convertToFloatArray(
        buffers: [first, second],
        inputFormat: format
    )

    #expect(converted.count == 16_000)
}

@Test func whisperTranscriptFormatterDropsHallucinatedWordsAfterSpeechTail() {
    let samples = [Float](repeating: 0, count: 16_000 * 12)
        + [Float](repeating: 0.05, count: 16_000)
        + [Float](repeating: 0, count: 16_000)
    let segment = WhisperTranscriptSegment(
        text: "Please peace",
        start: 12.2,
        end: 14.1,
        words: [
            WhisperTranscriptWord(word: "Please", start: 12.25, end: 12.8),
            WhisperTranscriptWord(word: " peace", start: 13.85, end: 14.05)
        ]
    )

    let transcript = WhisperKitTranscriptFormatter.transcript(
        from: [segment],
        audioSamples: samples
    )

    #expect(transcript == "Please")
}

@Test func whisperTranscriptFormatterPreservesFinalRealWordNearSpeechTail() {
    let samples = [Float](repeating: 0, count: 16_000 / 2)
        + [Float](repeating: 0.04, count: 16_000)
        + [Float](repeating: 0, count: 16_000 / 4)
    let segment = WhisperTranscriptSegment(
        text: "Looks good",
        start: 0.5,
        end: 1.75,
        words: [
            WhisperTranscriptWord(word: "Looks", start: 0.55, end: 0.85),
            WhisperTranscriptWord(word: " good", start: 1.35, end: 1.62)
        ]
    )

    let transcript = WhisperKitTranscriptFormatter.transcript(
        from: [segment],
        audioSamples: samples
    )

    #expect(transcript == "Looks good")
}

@Test func whisperTranscriptFormatterKeepsTextWhenWhisperKitTimestampsAreOutOfRange() {
    // WhisperKit reports word/segment timestamps far past the real audio for
    // short clips — observed: start=26.78s on a 1.1s clip. Trimming against a
    // cutoff derived from the real audio length must refine the tail, never
    // erase the whole transcript.
    let samples = [Float](repeating: 0.05, count: 16_000 * 11 / 10)
    let segment = WhisperTranscriptSegment(
        text: "<|startoftranscript|><|0.00|> Test, test, test.<|1.00|><|endoftext|>",
        start: 26.78,
        end: 29.78,
        words: [
            WhisperTranscriptWord(word: " Test,", start: 26.78, end: 27.50),
            WhisperTranscriptWord(word: " test,", start: 27.50, end: 28.30),
            WhisperTranscriptWord(word: " test.", start: 28.30, end: 29.18)
        ]
    )

    let transcript = WhisperKitTranscriptFormatter.transcript(
        from: [segment],
        audioSamples: samples
    )

    #expect(transcript == "Test, test, test.")
}

private func makeBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ))
    buffer.frameLength = AVAudioFrameCount(samples.count)

    let channel = try #require(buffer.floatChannelData?[0])
    for (index, sample) in samples.enumerated() {
        channel[index] = sample
    }

    return buffer
}

private func makeRampBuffer(frameCount: Int, start: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
    ))
    buffer.frameLength = AVAudioFrameCount(frameCount)

    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<frameCount {
        channel[index] = Float((start + index) % 100) / 100
    }

    return buffer
}
