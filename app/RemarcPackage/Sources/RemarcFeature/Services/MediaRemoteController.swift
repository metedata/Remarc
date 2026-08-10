import AudioToolbox
import CoreAudio
import Foundation

/// Mutes system audio during voice recording and restores afterward.
///
/// Uses CoreAudio to mute/unmute the default output device. This is the most
/// reliable cross-version approach — MediaRemote private framework commands
/// are blocked on macOS 15.4+ without special entitlements.
@MainActor
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    /// Whether we muted audio for the current recording session.
    private var didMuteForSession = false

    /// The volume level before we muted, so we can restore it.
    private var savedVolume: Float32?

    private init() {}

    // MARK: - Public API

    /// Mute system audio if setting is enabled. Call when recording starts.
    func pauseIfPlaying() {
        guard SettingsManager.shared.pauseMusicWhileRecording else {
            debugLog("MediaRemoteController: Mute setting is off, skipping")
            return
        }

        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else {
            debugLog("MediaRemoteController: No default output device")
            return
        }

        // Check if already muted (don't override user's mute)
        let currentlyMuted = getMute(device: deviceID)
        if currentlyMuted {
            didMuteForSession = false
            debugLog("MediaRemoteController: Already muted, skipping")
            return
        }

        // Save current volume and mute
        savedVolume = getVolume(device: deviceID)
        setMute(device: deviceID, muted: true)
        didMuteForSession = true
        debugLog("MediaRemoteController: Muted audio (savedVolume=\(savedVolume ?? -1))")
    }

    /// Unmute system audio if we muted it. Call when recording stops.
    func resumeIfWePaused() {
        guard didMuteForSession else { return }

        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        setMute(device: deviceID, muted: false)

        // Restore volume in case muting zeroed it on some devices
        if let vol = savedVolume {
            setVolume(device: deviceID, volume: vol)
        }

        didMuteForSession = false
        savedVolume = nil
        debugLog("MediaRemoteController: Unmuted audio")
    }

    // MARK: - CoreAudio Helpers

    private func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func getMute(device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return muted != 0
    }

    private func setMute(device: AudioDeviceID, muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
    }

    private func getVolume(device: AudioDeviceID) -> Float32 {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return volume
    }

    private func setVolume(device: AudioDeviceID, volume: Float32) {
        var vol = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &vol
        )
    }
}
