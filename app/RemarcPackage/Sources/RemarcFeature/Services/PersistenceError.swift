import Foundation

/// Why a durable document write did not reach disk.
///
/// The surrounding code swallows every one of these (`saveToDisk` catches and
/// logs, `saveNow` returns Void). That is tolerable for a debounced save, whose
/// next mutation retries, and not tolerable for a capture save, which deletes an
/// overlay, a draft, and an annotation session on the strength of the write
/// having succeeded. Surfacing the failure is the point of the type.
public enum PersistenceError: Error, Equatable, Sendable {
    /// Another process held the document lock past `DocumentLock`'s timeout.
    case lockTimeout
    /// The document exists but could not be read or decoded. Deliberately NOT
    /// recoverable by falling back to `lastPersisted`: overwriting a malformed,
    /// briefly unreadable, or forward-incompatible document with stale state
    /// destroys whatever a newer build wrote.
    case documentUnreadable(String)
    case encodeFailed(String)
    case writeFailed(String)
    /// The proposed record violates the canonical save policy. Currently this
    /// means a Quick Note has no meaningful body.
    case invalidComment
    /// The comment's target session was deleted by another writer between
    /// staging and encoding. Writing anyway would leave a comment that exists but
    /// is unreachable from navigation.
    case sessionUnavailable

    public var userMessage: String {
        switch self {
        case .lockTimeout:
            return "Another Remarc process is busy writing. Try again."
        case .documentUnreadable:
            return "Could not read the comments file. Nothing was changed."
        case .encodeFailed, .writeFailed:
            return "Could not save the comment to disk."
        case .invalidComment:
            return "Quick Notes need a comment."
        case .sessionUnavailable:
            return "That session was deleted while saving. Nothing was changed."
        }
    }
}
