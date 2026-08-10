import Testing
@testable import RemarcFeature

@Test func critModeNormalizerConvertsAllCapsToSentenceCase() {
    #expect(
        CritModeTextNormalizer.sentenceCaseIfAllCaps("MOVE THE BUTTON HIGHER.")
            == "Move the button higher."
    )
    #expect(
        CritModeTextNormalizer.sentenceCaseIfAllCaps("\u{201C}MAKE THIS CLEARER\u{201D}")
            == "\u{201C}Make this clearer\u{201D}"
    )
}

@Test func critModeNormalizerPreservesExistingMixedCase() {
    let text = "Keep the API label as-is."
    #expect(CritModeTextNormalizer.sentenceCaseIfAllCaps(text) == text)
}

@Test func critModeNormalizerPreservesTextWithoutCasedCharacters() {
    let text = "123 \u{2014} \u{2705}"
    #expect(CritModeTextNormalizer.sentenceCaseIfAllCaps(text) == text)
}
