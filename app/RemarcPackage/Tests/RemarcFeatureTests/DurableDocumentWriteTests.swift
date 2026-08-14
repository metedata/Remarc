import XCTest
@testable import RemarcFeature

/// The lock-held read/merge/encode/rename primitive that `createCommentDurably`
/// runs off the main actor. Driven against a temporary file so the real
/// `comments.json` is never touched.
final class DurableDocumentWriteTests: XCTestCase {

    private var dir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remarc-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("comments.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func session(_ name: String = "Inbox") -> Session { Session(name: name) }

    private func comment(in sessionID: UUID, text: String = "hello") -> Comment {
        Comment(type: .comment(text: "sel"), commentText: text,
                source: "test", appBundleID: nil, sessionID: sessionID)
    }

    private func write(_ state: AppState) throws {
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
    }

    private func read() throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: try Data(contentsOf: fileURL))
    }

    // MARK: - Happy paths

    func testMissingFileBootstrapsRatherThanFailing() throws {
        let s = session()
        var candidate = AppState(sessions: [s], activeSessionID: s.id)
        candidate.comments = [comment(in: s.id)]
        candidate.totalCommentsCreated = 1

        let merged = try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate,
            baseline: AppState.defaultState(), requiredSessionID: s.id)

        XCTAssertEqual(merged.comments.count, 1)
        XCTAssertEqual(try read().comments.count, 1)
    }

    func testAConcurrentExternalEditSurvivesTheMerge() throws {
        // The whole reason the write re-reads under the lock: an agent resolving a
        // comment must not be reverted by the next capture save.
        let s = session()
        let existing = comment(in: s.id, text: "original")
        let baseline = AppState(sessions: [s], comments: [existing],
                                activeSessionID: s.id, totalCommentsCreated: 1)
        try write(baseline)

        // Another process resolves it while we stage.
        var onDisk = baseline
        onDisk.comments[0].status = .resolved
        onDisk.comments[0].resolutionSummary = "done by an agent"
        try write(onDisk)

        var candidate = baseline
        candidate.comments.append(comment(in: s.id, text: "new"))
        candidate.totalCommentsCreated = 2

        let merged = try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate, baseline: baseline, requiredSessionID: s.id)

        XCTAssertEqual(merged.comments.count, 2)
        XCTAssertEqual(merged.comments.first { $0.id == existing.id }?.status, .resolved,
                       "the external resolution must survive")
        XCTAssertEqual(merged.comments.first { $0.id == existing.id }?.resolutionSummary,
                       "done by an agent")
        XCTAssertTrue(merged.comments.contains { $0.commentText == "new" })
    }

    func testTheCounterIncrementIsCarriedInsideTheCandidate() throws {
        // The counter is part of the encoded document and the merge resolves it by
        // max, so incrementing after the write would diverge memory from disk.
        let s = session()
        let baseline = AppState(sessions: [s], activeSessionID: s.id, totalCommentsCreated: 7)
        try write(baseline)

        var candidate = baseline
        candidate.comments = [comment(in: s.id)]
        candidate.totalCommentsCreated = 8

        let merged = try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate, baseline: baseline, requiredSessionID: s.id)

        XCTAssertEqual(merged.totalCommentsCreated, 8)
        XCTAssertEqual(try read().totalCommentsCreated, 8)
    }

    func testAFreshCommentIsAlwaysPresentInTheMergedResult() throws {
        let s = session()
        let baseline = AppState(sessions: [s], activeSessionID: s.id)
        try write(baseline)

        let fresh = comment(in: s.id, text: "fresh")
        var candidate = baseline
        candidate.comments = [fresh]

        let merged = try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate, baseline: baseline, requiredSessionID: s.id)

        XCTAssertNotNil(merged.comments.first { $0.id == fresh.id },
                        "an entity in ours and absent from base takes the we-created-it branch")
    }

    // MARK: - Export receipt clearing

    func testExportClearRereadsDiskAndSkipsAConcurrentAgentEdit() throws {
        let s = session()
        let exportedAt = Date(timeIntervalSince1970: 1_000)
        let exported = Comment(
            type: .comment(text: "selected"),
            commentText: "before",
            source: "test",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: s.id
        )
        let baseline = AppState(
            sessions: [s],
            comments: [exported],
            activeSessionID: s.id,
            totalCommentsCreated: 1
        )
        let receipt = ExportReceipt(sessionID: s.id, comments: [exported])

        var agentState = baseline
        agentState.comments[0].commentText = "edited by agent"
        agentState.comments[0].updatedAt = exportedAt.addingTimeInterval(1)
        try write(agentState)

        let commit = try PersistenceManager.performExportReceiptClear(
            fileURL: fileURL,
            receipt: receipt,
            candidate: baseline,
            baseline: baseline
        )

        XCTAssertTrue(commit.clearedIDs.isEmpty)
        let stored = try XCTUnwrap(try read().comments.first)
        XCTAssertEqual(stored.commentText, "edited by agent")
        XCTAssertFalse(stored.isDeleted)
    }

    func testExportClearSkipsAPendingLocalEditThatHasNotReachedDisk() throws {
        let s = session()
        let exportedAt = Date(timeIntervalSince1970: 2_000)
        let exported = Comment(
            type: .comment(text: "selected"),
            commentText: "before",
            source: "test",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: s.id
        )
        let baseline = AppState(
            sessions: [s],
            comments: [exported],
            activeSessionID: s.id,
            totalCommentsCreated: 1
        )
        try write(baseline)
        let receipt = ExportReceipt(sessionID: s.id, comments: [exported])

        var candidate = baseline
        candidate.comments[0].commentText = "pending local edit"
        candidate.comments[0].updatedAt = exportedAt.addingTimeInterval(1)

        let commit = try PersistenceManager.performExportReceiptClear(
            fileURL: fileURL,
            receipt: receipt,
            candidate: candidate,
            baseline: baseline
        )

        XCTAssertTrue(commit.clearedIDs.isEmpty)
        let stored = try XCTUnwrap(try read().comments.first)
        XCTAssertEqual(stored.commentText, "pending local edit")
        XCTAssertFalse(stored.isDeleted)
    }

    func testExportClearDurablyDeletesOnlyTheUnchangedVersion() throws {
        let s = session()
        let exportedAt = Date(timeIntervalSince1970: 3_000)
        let unchanged = Comment(
            type: .screenshot(imagePath: "images/capture.png"),
            commentText: "",
            source: "test",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: s.id
        )
        let baseline = AppState(
            sessions: [s],
            comments: [unchanged],
            activeSessionID: s.id,
            totalCommentsCreated: 1
        )
        try write(baseline)
        let receipt = ExportReceipt(sessionID: s.id, comments: [unchanged])

        let commit = try PersistenceManager.performExportReceiptClear(
            fileURL: fileURL,
            receipt: receipt,
            candidate: baseline,
            baseline: baseline
        )

        XCTAssertEqual(commit.clearedIDs, [unchanged.id])
        let stored = try XCTUnwrap(try read().comments.first)
        XCTAssertTrue(stored.isDeleted)
        XCTAssertNotNil(stored.deletedAt)
        XCTAssertGreaterThan(stored.updatedAt, exportedAt)
    }

    func testExportClearLeavesAnUnreadableDocumentUntouched() throws {
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let s = session()
        let exported = comment(in: s.id)
        let baseline = AppState(
            sessions: [s],
            comments: [exported],
            activeSessionID: s.id,
            totalCommentsCreated: 1
        )
        let receipt = ExportReceipt(sessionID: s.id, comments: [exported])

        XCTAssertThrowsError(try PersistenceManager.performExportReceiptClear(
            fileURL: fileURL,
            receipt: receipt,
            candidate: baseline,
            baseline: baseline
        )) { error in
            guard case PersistenceError.documentUnreadable = error else {
                return XCTFail("expected documentUnreadable, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), garbage,
                       "a failed export clear must not overwrite a newer or malformed document")
    }

    // MARK: - Failure paths

    func testAnUndecodableDocumentFailsWithoutWriting() throws {
        // saveToDisk falls back to lastPersisted here, which would overwrite a
        // malformed, briefly unreadable, or forward-incompatible document with
        // stale state and destroy whatever a newer build wrote.
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let s = session()
        var candidate = AppState(sessions: [s], activeSessionID: s.id)
        candidate.comments = [comment(in: s.id)]

        XCTAssertThrowsError(try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate,
            baseline: AppState.defaultState(), requiredSessionID: s.id)
        ) { error in
            guard case PersistenceError.documentUnreadable = error else {
                return XCTFail("expected documentUnreadable, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), garbage,
                       "the unreadable document must be left exactly as found")
    }

    func testADeletedTargetSessionFailsWithoutWriting() throws {
        // Sessions merge as whole entities, so a session another writer deleted
        // wins for that untouched entity while our new comment still points at it.
        // Deleted sessions are excluded from navigation: the comment would exist
        // and be invisible.
        var s = session("Work")
        let baseline = AppState(sessions: [s], activeSessionID: s.id)
        try write(baseline)

        s.isDeleted = true
        s.deletedAt = Date()
        let onDisk = AppState(sessions: [s], activeSessionID: nil)
        try write(onDisk)
        let before = try Data(contentsOf: fileURL)

        var candidate = baseline
        candidate.comments = [comment(in: baseline.sessions[0].id)]

        XCTAssertThrowsError(try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: candidate,
            baseline: baseline, requiredSessionID: baseline.sessions[0].id)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .sessionUnavailable)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), before,
                       "a conflict must not write")
    }

    func testAMissingTargetSessionFails() throws {
        let s = session()
        let baseline = AppState(sessions: [s], activeSessionID: s.id)
        try write(baseline)

        XCTAssertThrowsError(try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: baseline,
            baseline: baseline, requiredSessionID: UUID())
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .sessionUnavailable)
        }
    }

    func testAHeldLockSurfacesAsATimeoutRatherThanBeingSwallowed() throws {
        // saveToDisk logs and moves on here. A capture save cannot: it would tear
        // down the overlay and the draft on the strength of a write that never
        // happened.
        let baseline = AppState.defaultState()
        try write(baseline)
        let before = try Data(contentsOf: fileURL)

        // Hold the lock with a live owner so the stale-reclaim path cannot fire.
        let lockURL = DocumentLock.lockURL(for: fileURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let owner: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                    "at": Int(Date().timeIntervalSince1970 * 1000)]
        try JSONSerialization.data(withJSONObject: owner)
            .write(to: lockURL.appendingPathComponent("owner.json"))
        defer { try? FileManager.default.removeItem(at: lockURL) }

        XCTAssertThrowsError(try PersistenceManager.performDocumentWrite(
            fileURL: fileURL, candidate: baseline, baseline: baseline, requiredSessionID: nil)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .lockTimeout)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), before,
                       "a timed-out write must change nothing")
    }
}
