import Foundation

/// Defines whether a comment draft contains enough information to be saved.
///
/// Context-backed comments carry useful information independently of their
/// optional body. A Quick Note has no such context, so it requires meaningful
/// text even when an attachment is present.
public enum CommentSavePolicy {
    public static func allowsSave(
        type: CommentType,
        commentText: String,
        attachments: [String] = []
    ) -> Bool {
        guard type.isQuickNote else { return true }
        // Attachments intentionally do not make a context-free Quick Note valid.
        _ = attachments
        return !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Classifies an optional selection before validation. Whitespace does not
    /// provide useful context, so it follows the Quick Note rule.
    public static func type(forSelectionText text: String?) -> CommentType {
        guard let text else { return .quickNote }
        let normalizedSelection = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return normalizedSelection.isEmpty
            ? .quickNote
            : .comment(text: normalizedSelection)
    }
}
