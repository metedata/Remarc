import AppKit
import AVFoundation

public enum DictationHandsFreeMode: String, CaseIterable, Sendable {
    case singleTap = "Single tap"
    case doubleTap = "Double tap"
    case customShortcut = "Custom shortcut"
}

@MainActor
enum DictationSounds {
    private static let startVolume: Float = 0.5
    private static let stopVolume: Float = 0.3
    /// Pre-loaded player cache — avoids disk I/O on the hotkey path and keeps
    /// each player alive so ARC doesn't deallocate mid-playback.
    private static var cache: [String: AVAudioPlayer] = [:]

    /// Minimum time the start sound needs before system audio can be muted.
    private static let minStartSoundDuration: Duration = .milliseconds(350)

    static func playStart() {
        play("wood_start", volume: startVolume)
    }

    static func playStop() {
        play("wood_stop", volume: stopVolume)
    }

    static func playError() {
        play("wood2_error", volume: stopVolume)
    }

    /// Plays the start sound and schedules a deferred system mute so the sound
    /// is audible. Returns a cancellable task - cancel it in stop/cancel paths
    /// to prevent muting after recording has already ended.
    @discardableResult
    static func playStartAndDeferMute() -> Task<Void, Never> {
        let soundsEnabled = SettingsManager.shared.soundEffectsEnabled
        if soundsEnabled { playStart() }
        let soundStart = ContinuousClock.now
        return Task { @MainActor in
            if soundsEnabled {
                let remaining = minStartSoundDuration - (ContinuousClock.now - soundStart)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }
            MediaRemoteController.shared.pauseIfPlaying()
        }
    }

    private static func play(_ name: String, volume: Float) {
        guard SettingsManager.shared.soundEffectsEnabled else { return }
        let player: AVAudioPlayer
        if let cached = cache[name] {
            cached.currentTime = 0
            player = cached
        } else {
            guard let url = Bundle.module.url(forResource: name, withExtension: "mp3") else {
                debugLog("DictationSounds: Could not find \(name).mp3 in bundle")
                return
            }
            do {
                player = try AVAudioPlayer(contentsOf: url)
                cache[name] = player
            } catch {
                debugLog("DictationSounds: Failed to play \(name): \(error)")
                return
            }
        }
        player.prepareToPlay()
        player.volume = volume
        player.play()
        debugLog("DictationSounds: Playing \(name)")
    }
}
