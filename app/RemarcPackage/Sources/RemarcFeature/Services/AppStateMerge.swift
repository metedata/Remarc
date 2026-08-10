import Foundation

/// Three-way merge for `AppState`.
///
/// The app holds a long-lived in-memory `appState` and writes whole-document
/// snapshots. Other processes (MCP tools, hooks) commit to the same file in
/// between. Writing our snapshot blindly erases their commits - an agent
/// resolves a comment, the next UI edit reverts it.
///
/// Merging by entity against the baseline we last read or wrote tells us who
/// actually changed what, so each side's edits survive:
///   - only we changed it  -> ours
///   - only they changed it -> theirs
///   - both changed it      -> ours (the user's live UI is the tiebreak)
///
/// Deletion is soft everywhere in Remarc (`isDeleted`), so an entity vanishing
/// from one side is an edit, not a removal, and needs no tombstone handling.
enum AppStateMerge {
    static func merge(base: AppState, ours: AppState, theirs: AppState) -> AppState {
        var result = ours

        // Comments merge field by field, not whole-entity. Whole-entity would
        // mean a pending local text edit re-writes the whole comment from stale
        // memory and rolls back an agent's status claim that landed meanwhile -
        // silently undoing a successful compare-and-set.
        result.comments = mergeEntities(
            base: base.comments, ours: ours.comments, theirs: theirs.comments,
            id: \.id, equal: { $0 == $1 }, combine: mergeComment
        )
        result.sessions = mergeEntities(
            base: base.sessions, ours: ours.sessions, theirs: theirs.sessions,
            id: \.id, equal: { $0 == $1 }, combine: mergeSession
        )
        result.transcriptions = mergeEntities(
            base: base.transcriptions, ours: ours.transcriptions, theirs: theirs.transcriptions,
            id: \.id, equal: { $0 == $1 }
        )
        result.orphanedImages = mergeEntities(
            base: base.orphanedImages, ours: ours.orphanedImages, theirs: theirs.orphanedImages,
            id: \.id, equal: { $0 == $1 }
        )

        // Scalars: keep ours when we changed it, otherwise take theirs.
        if ours.activeSessionID == base.activeSessionID {
            result.activeSessionID = theirs.activeSessionID
        }
        // Count both sides' additions rather than taking a max, which lost one
        // when two writers each created a comment. Never goes backwards.
        let oursAdded = max(0, ours.totalCommentsCreated - base.totalCommentsCreated)
        let theirsAdded = max(0, theirs.totalCommentsCreated - base.totalCommentsCreated)
        result.totalCommentsCreated = base.totalCommentsCreated + oursAdded + theirsAdded
        return result
    }

    /// Per-field three-way merge for a comment: each field independently goes
    /// to whichever side changed it, so local text edits and remote status
    /// changes both survive.
    private static func mergeComment(base: Comment, ours: Comment, theirs: Comment) -> Comment {
        var out = ours
        func pick<V: Equatable>(_ kp: WritableKeyPath<Comment, V>) {
            if ours[keyPath: kp] == base[keyPath: kp] {
                out[keyPath: kp] = theirs[keyPath: kp]
            }
        }
        pick(\.type)
        pick(\.commentText)
        pick(\.source)
        pick(\.appBundleID)
        pick(\.updatedAt)
        pick(\.sessionID)
        pick(\.isDeleted)
        pick(\.deletedAt)
        pick(\.status)
        pick(\.resolutionSummary)
        pick(\.resolvedBy)
        pick(\.resolvedAt)
        pick(\.attachments)
        pick(\.webContext)
        pick(\.regionElements)
        pick(\.wakeRequestedAt)
        return out
    }

    /// Per-field merge for a session, with deletion treated as a decision that
    /// cannot be undone by an unrelated concurrent edit: renaming a session
    /// locally must not resurrect one that SessionEnd just wound down.
    private static func mergeSession(base: Session, ours: Session, theirs: Session) -> Session {
        var out = ours
        func pick<V: Equatable>(_ kp: WritableKeyPath<Session, V>) {
            if ours[keyPath: kp] == base[keyPath: kp] {
                out[keyPath: kp] = theirs[keyPath: kp]
            }
        }
        pick(\.name)
        pick(\.origin)
        pick(\.claudeCodeSessionId)
        pick(\.isDeleted)
        pick(\.deletedAt)
        pick(\.isAutoDismissed)
        pick(\.autoDismissedAt)
        // Whoever removed it wins, regardless of what the other side changed.
        if theirs.isDeleted || ours.isDeleted {
            out.isDeleted = true
            out.deletedAt = ours.deletedAt ?? theirs.deletedAt
        }
        if theirs.isAutoDismissed || ours.isAutoDismissed {
            out.isAutoDismissed = true
            out.autoDismissedAt = ours.autoDismissedAt ?? theirs.autoDismissedAt
        }
        return out
    }

    private static func mergeEntities<T, ID: Hashable>(
        base: [T], ours: [T], theirs: [T],
        id: KeyPath<T, ID>,
        equal: (T, T) -> Bool,
        combine: ((T, T, T) -> T)? = nil
    ) -> [T] {
        let baseByID = Dictionary(base.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { a, _ in a })
        let theirsByID = Dictionary(theirs.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { a, _ in a })

        var merged: [T] = []
        var seen = Set<ID>()

        // Preserve our ordering first, then append anything only they have.
        for item in ours {
            let key = item[keyPath: id]
            seen.insert(key)
            guard let baseItem = baseByID[key] else {
                merged.append(item) // we created it
                continue
            }
            guard let theirItem = theirsByID[key] else {
                merged.append(item) // they dropped it entirely; keep ours
                continue
            }
            let weChanged = !equal(item, baseItem)
            let theyChanged = !equal(theirItem, baseItem)
            switch (weChanged, theyChanged) {
            case (true, true):
                // Both sides touched it: merge field by field when we know how,
                // otherwise the live UI wins.
                merged.append(combine?(baseItem, item, theirItem) ?? item)
            case (true, false): merged.append(item)
            case (false, true): merged.append(theirItem)
            case (false, false): merged.append(item)
            }
        }

        for item in theirs where !seen.contains(item[keyPath: id]) {
            // Created by another process since our baseline.
            if baseByID[item[keyPath: id]] == nil {
                merged.append(item)
            }
        }

        return merged
    }
}
