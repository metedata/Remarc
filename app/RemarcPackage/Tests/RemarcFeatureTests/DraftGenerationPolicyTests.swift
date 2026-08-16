import Testing
@testable import RemarcFeature

@Suite("Draft generation policy")
struct DraftGenerationPolicyTests {
    @Test("Accepts output from the visible current draft")
    func acceptsCurrentVisibleDraft() {
        #expect(DraftGenerationPolicy.accepts(
            capturedGeneration: 4,
            currentGeneration: 4,
            isVisible: true
        ))
    }

    @Test("Rejects output from a replaced draft")
    func rejectsReplacedDraft() {
        #expect(!DraftGenerationPolicy.accepts(
            capturedGeneration: 4,
            currentGeneration: 5,
            isVisible: true
        ))
    }

    @Test("Rejects output after dismissal")
    func rejectsDismissedDraft() {
        #expect(!DraftGenerationPolicy.accepts(
            capturedGeneration: 4,
            currentGeneration: 4,
            isVisible: false
        ))
    }
}
