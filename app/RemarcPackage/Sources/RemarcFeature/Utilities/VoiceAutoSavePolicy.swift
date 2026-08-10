import Foundation

enum VoiceAutoSavePolicy {
    static func shouldStartCountdown(
        isVoiceInvoked: Bool,
        autoSaveEnabled: Bool,
        text: String,
        allowsAutoSave: Bool = true
    ) -> Bool {
        isVoiceInvoked
            && autoSaveEnabled
            && allowsAutoSave
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
