/// Accept asynchronous draft output only while the presentation that launched
/// it is still the visible owner of the editor.
enum DraftGenerationPolicy {
    static func accepts(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        isVisible: Bool
    ) -> Bool {
        isVisible && capturedGeneration == currentGeneration
    }
}
