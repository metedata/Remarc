import Foundation
import Testing
@testable import RemarcFeature

private typealias AppComment = RemarcFeature.Comment

@Suite("Comment count policy")
struct CommentCountPolicyTests {
    private func comment(
        sessionID: UUID = UUID(),
        status: CommentStatus,
        isDeleted: Bool = false
    ) -> AppComment {
        AppComment(
            type: .quickNote,
            commentText: "Test",
            source: "Tests",
            appBundleID: nil,
            sessionID: sessionID,
            isDeleted: isDeleted,
            status: status
        )
    }

    @Test("All actionable statuses count, while resolved and deleted comments do not")
    func countsOnlyOutstandingComments() {
        let comments = [
            comment(status: .open),
            comment(status: .handedOff),
            comment(status: .inProgress),
            comment(status: .resolved),
            comment(status: .open, isDeleted: true),
            comment(status: .resolved, isDeleted: true),
        ]

        #expect(CommentCountPolicy.unresolvedCount(in: comments) == 3)
    }

    @Test("Resolving retained comments drops the visible count to zero")
    func resolvingCommentsClearsTheCounter() {
        var comments = [
            comment(status: .open),
            comment(status: .handedOff),
            comment(status: .inProgress),
        ]
        #expect(CommentCountPolicy.unresolvedCount(in: comments) == 3)

        for index in comments.indices {
            comments[index].status = .resolved
        }

        #expect(CommentCountPolicy.unresolvedCount(in: comments) == 0)
        #expect(comments.allSatisfy { !$0.isDeleted })
    }

    @Test("Session counters include only unresolved comments in their own session")
    func groupsOutstandingCommentsBySession() {
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let resolvedOnlySessionID = UUID()
        let counts = CommentCountPolicy.unresolvedCountsBySession(in: [
            comment(sessionID: firstSessionID, status: .open),
            comment(sessionID: firstSessionID, status: .inProgress),
            comment(sessionID: firstSessionID, status: .resolved),
            comment(sessionID: secondSessionID, status: .handedOff),
            comment(sessionID: secondSessionID, status: .open, isDeleted: true),
            comment(sessionID: resolvedOnlySessionID, status: .resolved),
        ])

        #expect(counts[firstSessionID] == 2)
        #expect(counts[secondSessionID] == 1)
        #expect(counts[resolvedOnlySessionID] == nil)
    }
}
