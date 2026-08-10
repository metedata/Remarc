import Testing
@testable import RemarcFeature

@Suite("Voice auto-save policy")
struct VoiceAutoSavePolicyTests {
    @Test("Starts for voice-invoked non-empty text when enabled")
    func startsForVoiceInvokedTextWhenEnabled() {
        #expect(VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: true,
            autoSaveEnabled: true,
            text: "Dictated quick note"
        ))
    }

    @Test("Does not start for manually edited text")
    func doesNotStartForManualText() {
        #expect(!VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: false,
            autoSaveEnabled: true,
            text: "Manual quick note"
        ))
    }

    @Test("Does not start when setting is disabled")
    func doesNotStartWhenDisabled() {
        #expect(!VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: true,
            autoSaveEnabled: false,
            text: "Dictated quick note"
        ))
    }

    @Test("Does not start for whitespace text")
    func doesNotStartForWhitespace() {
        #expect(!VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: true,
            autoSaveEnabled: true,
            text: " \n\t "
        ))
    }

    @Test("Can be disabled for editor contexts that should not auto-save")
    func respectsEditorSupportFlag() {
        #expect(!VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: true,
            autoSaveEnabled: true,
            text: "Update existing comment",
            allowsAutoSave: false
        ))
    }
}
