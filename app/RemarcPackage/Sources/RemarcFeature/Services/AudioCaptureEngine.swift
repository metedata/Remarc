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
    private var inputOverride: AudioInputDeviceOverride?
    private(set) var inputFormat: AVAudioFormat?

    /// Set up and start the audio engine + tap. Must be called off MainActor.
    /// Reuses the existing AVAudioEngine if available - creating a second
    /// instance after tearing down the first causes the tap to silently stop
    /// firing on macOS.
    func start(smartMicrophoneSelection: Bool) throws {
        // Always create a fresh engine. Reusing an engine whose input device
        // changed causes installTap to throw an uncatchable NSException, and
        // calling reset() after stop() leaves the audio graph unable to
        // accept a new tap. A fresh instance avoids both issues.
        engine?.stop()
        engine = nil
        inputOverride?.restore()
        inputOverride = nil

        let override = smartMicrophoneSelection
            ? AudioInputDeviceSelector.activatePreferredDefaultInput()
            : nil
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        if smartMicrophoneSelection {
            AudioInputDeviceSelector.applyPreferredDevice(to: inputNode)
        }
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            override?.restore()
            throw NSError(domain: "AudioCaptureEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No valid audio input device available"])
        }

        // Clear stale pending data from previous recording
        lock.lock()
        pending = []
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))

            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
            if let copyChannelData = copy.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(copyChannelData[channel], channelData[channel], byteCount)
                }
            }

            self.append(rms: rms, buffer: copy)
        }

        do {
            try eng.start()
        } catch {
            override?.restore()
            throw error
        }
        self.engine = eng
        self.inputOverride = override
        self.inputFormat = format
    }

    func stop() {
        _ = stopAndDrain()
    }

    func stopAndDrain() -> [(Float, AVAudioPCMBuffer)] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        inputOverride?.restore()
        inputOverride = nil
        return drain()
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
