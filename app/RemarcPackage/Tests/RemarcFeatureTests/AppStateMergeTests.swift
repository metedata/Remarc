import XCTest
@testable import RemarcFeature

/// The app writes whole-document snapshots from long-lived memory while the MCP
/// server and hooks write the same file from Node. These cover the merge that
/// keeps one side's commits from erasing the other's.
final class AppStateMergeTests: XCTestCase {
    private func comment(
        _ id: UUID,
        text: String = "text",
        status: CommentStatus = .open,
        session: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        wakeRequestedAt: Date? = nil
    ) -> Comment {
        Comment(
            id: id,
            type: .quickNote,
            commentText: text,
            source: "test",
            appBundleID: nil,
            sessionID: session,
            status: status,
            wakeRequestedAt: wakeRequestedAt
        )
    }

    private func state(_ comments: [Comment], total: Int = 0) -> AppState {
        AppState(sessions: [], comments: comments, activeSessionID: nil, totalCommentsCreated: total)
    }

    func testAgentStatusChangeSurvivesUnrelatedLocalEdit() {
        let a = UUID(), b = UUID()
        let base = state([comment(a), comment(b)])
        var ours = base
        ours.comments[0].commentText = "locally edited"      // user edits A
        var theirs = base
        theirs.comments[1].status = .resolved                 // agent resolves B

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.comments[0].commentText, "locally edited")
        XCTAssertEqual(merged.comments[1].status, .resolved)
    }

    func testAgentClaimSurvivesLocalEditOfTheSameComment() {
        // The case whole-entity merging gets wrong: a pending text edit would
        // rewrite the whole comment from stale memory and roll back the agent's
        // compare-and-set claim.
        let id = UUID()
        let base = state([comment(id, text: "original", status: .handedOff)])
        var ours = base
        ours.comments[0].commentText = "edited while the agent worked"
        var theirs = base
        theirs.comments[0].status = .inProgress

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.comments[0].commentText, "edited while the agent worked")
        XCTAssertEqual(merged.comments[0].status, .inProgress, "the agent's claim must not be rolled back")
    }

    func testKeepsCommentsCreatedByEitherSide() {
        let existing = UUID()
        let base = state([comment(existing)])
        var ours = base
        ours.comments.append(comment(UUID(), text: "ours"))
        var theirs = base
        theirs.comments.append(comment(UUID(), text: "theirs"))

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.comments.count, 3)
        XCTAssertTrue(merged.comments.contains { $0.commentText == "ours" })
        XCTAssertTrue(merged.comments.contains { $0.commentText == "theirs" })
    }

    func testWakeFlagSurvivesAConcurrentAgentWrite() {
        let id = UUID()
        let base = state([comment(id)])
        var ours = base
        ours.comments[0].wakeRequestedAt = Date(timeIntervalSince1970: 1000)
        ours.comments[0].status = .handedOff
        var theirs = base
        theirs.comments[0].commentText = "agent touched this"

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertNotNil(merged.comments[0].wakeRequestedAt)
        XCTAssertEqual(merged.comments[0].status, .handedOff)
        XCTAssertEqual(merged.comments[0].commentText, "agent touched this")
    }

    func testCounterSumsBothSidesAdditions() {
        // Additive, not max: with base 5, one side adding 1 and the other 2
        // means 3 comments were created, so the counter must reach 8.
        let base = state([], total: 5)
        var ours = base; ours.totalCommentsCreated = 6
        var theirs = base; theirs.totalCommentsCreated = 7

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.totalCommentsCreated, 8)
    }

    func testCounterNeverGoesBackwards() {
        let base = state([], total: 5)
        let merged = AppStateMerge.merge(base: base, ours: base, theirs: base)
        XCTAssertEqual(merged.totalCommentsCreated, 5)
    }

    func testUnchangedSideDoesNotOverwrite() {
        let id = UUID()
        let base = state([comment(id, status: .open)])
        let ours = base                       // we changed nothing
        var theirs = base
        theirs.comments[0].status = .resolved // agent resolved it

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.comments[0].status, .resolved)
    }
}

extension AppStateMergeTests {
    private func session(_ id: UUID, name: String, deleted: Bool = false) -> Session {
        var s = Session(name: name)
        s = Session(
            id: id, name: name, createdAt: Date(timeIntervalSince1970: 0),
            isDeleted: deleted, deletedAt: deleted ? Date() : nil,
            isAutoDismissed: false, autoDismissedAt: nil,
            origin: .manual, claudeCodeSessionId: nil
        )
        return s
    }

    func testRemoteSessionDeletionSurvivesLocalRename() {
        // SessionEnd wind-down deletes a session while the user renames it.
        // Whole-entity "ours wins" used to resurrect it.
        let id = UUID()
        let base = AppState(sessions: [session(id, name: "Proj")], comments: [])
        var ours = base
        ours.sessions[0].name = "Renamed"
        var theirs = base
        theirs.sessions[0].isDeleted = true
        theirs.sessions[0].deletedAt = Date()

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertTrue(merged.sessions[0].isDeleted, "a remote deletion must not be undone by a local rename")
        XCTAssertEqual(merged.sessions[0].name, "Renamed")
    }

    func testConcurrentCreationCountsBoth() {
        let base = AppState(sessions: [], comments: [], activeSessionID: nil, totalCommentsCreated: 5)
        var ours = base; ours.totalCommentsCreated = 6
        var theirs = base; theirs.totalCommentsCreated = 6

        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)

        XCTAssertEqual(merged.totalCommentsCreated, 7, "both additions must count")
    }
}
