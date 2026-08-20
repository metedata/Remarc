import Foundation

/// Defines which retained comments contribute to the app's visible counters.
///
/// Resolved comments remain available in their sessions for review and export,
/// but they no longer represent outstanding work. Deleted comments are excluded
/// regardless of status.
public enum CommentCountPolicy {
    public static func includes(_ comment: Comment) -> Bool {
        !comment.isDeleted && comment.status != .resolved
    }

    public static func unresolvedCount(in comments: [Comment]) -> Int {
        comments.reduce(into: 0) { count, comment in
            if includes(comment) {
                count += 1
            }
        }
    }

    public static func unresolvedCountsBySession(in comments: [Comment]) -> [UUID: Int] {
        comments.reduce(into: [:]) { counts, comment in
            guard includes(comment) else { return }
            counts[comment.sessionID, default: 0] += 1
        }
    }
}
