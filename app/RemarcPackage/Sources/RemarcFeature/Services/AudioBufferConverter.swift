@preconcurrency import AVFAudio
import Foundation

/// Shared audio buffer conversion utility.
/// Converts `[AVAudioPCMBuffer]` to 16kHz mono Float32 for transcription engines.
enum AudioBufferConverter {
    static func convertToFloatArray(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat,
        trailingSilenceDuration: TimeInterval = 0
    ) -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            debugLog("AudioBufferConverter: Failed to create target format")
            return []
        }

        let needsConversion = !(inputFormat.sampleRate == 16000 && inputFormat.channelCount == 1)
        var allSamples: [Float] = []

        if needsConversion {
            if let concatenatedBuffer = concatenate(buffers: buffers, format: inputFormat) {
                allSamples = convert(buffer: concatenatedBuffer, to: targetFormat)
            }
        } else {
            let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
            allSamples.reserveCapacity(totalFrames)
            for buffer in buffers {
                guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { continue }
                let frameCount = Int(buffer.frameLength)
                allSamples.append(contentsOf: UnsafeBufferPointer(
                    start: channelData[0], count: frameCount
                ))
            }
        }

        let trailingSilenceSamples = Int((max(0, trailingSilenceDuration) * targetFormat.sampleRate).rounded(.up))
        if trailingSilenceSamples > 0 {
            allSamples.append(contentsOf: repeatElement(Float.zero, count: trailingSilenceSamples))
        }

        let duration = Double(allSamples.count) / targetFormat.sampleRate
        debugLog("AudioBufferConverter: Converted \(buffers.count) buffers -> \(allSamples.count) samples (\(String(format: "%.2f", duration))s, padding=\(trailingSilenceSamples))")
        return allSamples
    }

    private static func concatenate(
        buffers: [AVAudioPCMBuffer],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }
        guard totalFrames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)
        else {
            return nil
        }

        for buffer in buffers {
            guard buffer.frameLength > 0,
                  let sourceData = buffer.floatChannelData,
                  let resultData = result.floatChannelData
            else {
                continue
            }

            let destinationOffset = Int(result.frameLength)
            let frameCount = Int(buffer.frameLength)
            let byteCount = frameCount * MemoryLayout<Float>.size
            let channelCount = min(Int(format.channelCount), Int(buffer.format.channelCount))

            for channel in 0..<channelCount {
                let destination = resultData[channel].advanced(by: destinationOffset)
                memcpy(destination, sourceData[channel], byteCount)
            }

            result.frameLength += buffer.frameLength
        }

        return result
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat
    ) -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            debugLog("AudioBufferConverter: Failed to create converter")
            return []
        }

        var samples: [Float] = []
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        samples.reserveCapacity(Int(Double(buffer.frameLength) * ratio))

        nonisolated(unsafe) var suppliedInput = false
        nonisolated(unsafe) var suppliedEndOfStream = false

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 16_384
            ) else {
                break
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if !suppliedInput {
                    suppliedInput = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if !suppliedEndOfStream {
                    suppliedEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            if let error {
                debugLog("AudioBufferConverter: Conversion error: \(error)")
                break
            }

            if let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channelData[0], count: frameCount
                ))
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if suppliedEndOfStream && convertedBuffer.frameLength == 0 {
                    return samples
                }
                continue
            case .endOfStream:
                return samples
            case .error:
                return samples
            @unknown default:
                return samples
            }
        }

        return samples
    }
}
