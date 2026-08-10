import Foundation
@preconcurrency import WhisperKit

enum VocabularyHints {
    static let defaultHints: [String] = ["Remarc", "Claude Code"]

    @MainActor
    static var words: [String] {
        SettingsManager.shared.vocabularyHints
    }

    @MainActor
    static func whisperPromptTokens(using tokenizer: WhisperTokenizer) -> [Int] {
        tokenizer.encode(text: words.joined(separator: ", "))
    }
}
