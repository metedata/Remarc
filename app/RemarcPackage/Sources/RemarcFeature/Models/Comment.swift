import Foundation

public struct Comment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var type: CommentType
    public var commentText: String
    public var source: String
    public var appBundleID: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var sessionID: UUID
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var status: CommentStatus
    public var resolutionSummary: String?
    public var resolvedBy: String?
    public var resolvedAt: Date?
    public var attachments: [String]
    public var webContext: WebContext?
    public var regionElements: [WebContext]?
    /// Set when the user sends a comment with "Send instantly & save".
    /// A paired agent integration reads it to decide whether to wake its session.
    /// Never cleared - delivery state lives in each session's marker.
    public var wakeRequestedAt: Date?

    public init(
        id: UUID = UUID(),
        type: CommentType,
        commentText: String,
        source: String,
        appBundleID: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sessionID: UUID,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        status: CommentStatus = .open,
        resolutionSummary: String? = nil,
        resolvedBy: String? = nil,
        resolvedAt: Date? = nil,
        attachments: [String] = [],
        webContext: WebContext? = nil,
        regionElements: [WebContext]? = nil,
        wakeRequestedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.commentText = Self.normalizedCommentText(commentText)
        self.source = source
        self.appBundleID = appBundleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionID = sessionID
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.status = status
        self.resolutionSummary = resolutionSummary
        self.resolvedBy = resolvedBy
        self.resolvedAt = resolvedAt
        self.attachments = attachments
        self.webContext = webContext
        self.regionElements = regionElements
        self.wakeRequestedAt = wakeRequestedAt
    }

    // MARK: - Short ID

    /// A short, human-readable identifier derived from the UUID (first 5 hex chars).
    /// Used for display and AI agent references. Example: "a3f2b"
    public var shortID: String {
        String(id.uuidString.prefix(5)).lowercased()
    }

    // MARK: - Comment Body Semantics

    /// Canonical storage representation for a comment body. Whitespace-only
    /// contextual comments are valid records, but they have no semantic body and
    /// are stored as an empty string rather than invisible whitespace.
    public static func normalizedCommentText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// The body when it contains something meaningful to render or export.
    /// This also treats historical whitespace-only values as empty even if they
    /// predate canonicalization at the persistence boundary.
    public var meaningfulCommentText: String? {
        let normalized = Self.normalizedCommentText(commentText)
        return normalized.isEmpty ? nil : normalized
    }

    public var hasMeaningfulCommentText: Bool {
        meaningfulCommentText != nil
    }

    // MARK: - Compatibility Properties

    /// The selected text, if this comment references a text selection.
    /// Backward-compatible computed property.
    public var selectedText: String? {
        type.displayText
    }

    /// Whether this is a standalone note (no text selection)
    public var isStandaloneNote: Bool {
        type.isQuickNote
    }

    /// Truncated type label for display
    public var truncatedTypeLabel: String {
        switch type {
        case .screenshot:
            return "Screenshot"
        case .quickNote:
            return "Quick Note"
        case .critMode:
            return "Crit Mode"
        case .comment(let text):
            let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if cleaned.count > AppConstants.maxReferenceTextLength {
                return String(cleaned.prefix(AppConstants.maxReferenceTextLength)) + "..."
            }
            return cleaned
        case .webElement(let name, let path):
            // Smart identification: prefer meaningful component name + path. Fall
            // back to elementName (text-content based, like "button [Play]") when
            // the React fiber name is missing or minified (back-compat with
            // comments captured before the extension filter landed).
            let smart = WebContext.smartLabel(componentName: name, elementName: webContext?.elementName)
            let parts = [smart, path].compactMap { $0 }
            return parts.isEmpty ? "Web Element" : parts.joined(separator: " · ")
        }
    }
}
