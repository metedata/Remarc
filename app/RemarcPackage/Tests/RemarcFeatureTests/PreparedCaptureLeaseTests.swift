import XCTest
@testable import RemarcFeature

/// Reconciliation must never behave like a directory sweep. Remarc keeps images
/// on disk that no comment references and that a sweep would destroy: retained
/// orphans from pruned comments, and attachments written before any comment
/// points at them.
final class PreparedCaptureLeaseTests: XCTestCase {

    private func lease(_ path: String,
                       pid: Int32 = 424242,
                       bootTime: Int64 = 1_000,
                       startTime: Int64 = 5_000) -> PreparedCaptureLease {
        PreparedCaptureLease(path: path, pid: pid, bootTime: bootTime,
                             startTime: startTime, at: 1_700_000_000)
    }

    // MARK: - Owner identity

    func testALiveOwnerIsNeverAbandonedHoweverOld() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = PreparedCaptureLeaseRegistry.processStartTime(pid: me)
        XCTAssertNotNil(start, "this process must be able to read its own start time")

        let ancient = PreparedCaptureLease(
            path: "images/\(UUID().uuidString).png",
            pid: me,
            bootTime: PreparedCaptureLeaseRegistry.currentBootTime(),
            startTime: start ?? 0,
            at: 0)   // epoch: as old as a timestamp can be
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isAbandoned(ancient),
                       "age alone must never reclaim a live owner")
    }

    func testADeadPidIsAbandoned() {
        // A PID that cannot be running: the max is 99998 on Darwin.
        let dead = lease("images/\(UUID().uuidString).png",
                         pid: 99_999,
                         bootTime: PreparedCaptureLeaseRegistry.currentBootTime())
        XCTAssertTrue(PreparedCaptureLeaseRegistry.isAbandoned(dead))
    }

    func testARecycledPidIsAbandoned() {
        // Same PID, live, but a start time that is not the one recorded.
        let me = ProcessInfo.processInfo.processIdentifier
        let recycled = PreparedCaptureLease(
            path: "images/\(UUID().uuidString).png",
            pid: me,
            bootTime: PreparedCaptureLeaseRegistry.currentBootTime(),
            startTime: 1,   // not this process's actual start
            at: Date().timeIntervalSince1970)
        XCTAssertTrue(PreparedCaptureLeaseRegistry.isAbandoned(recycled),
                      "a live PID with a different start time was recycled")
    }

    func testADifferentBootMakesEveryPidMeaningless() {
        let me = ProcessInfo.processInfo.processIdentifier
        let previousBoot = PreparedCaptureLease(
            path: "images/\(UUID().uuidString).png",
            pid: me,
            bootTime: PreparedCaptureLeaseRegistry.currentBootTime() - 1,
            startTime: PreparedCaptureLeaseRegistry.processStartTime(pid: me) ?? 0,
            at: Date().timeIntervalSince1970)
        XCTAssertTrue(PreparedCaptureLeaseRegistry.isAbandoned(previousBoot))
    }

    // MARK: - Path containment

    func testOnlyGeneratedImagePathsAreDeletable() {
        XCTAssertTrue(PreparedCaptureLeaseRegistry
            .isDeletableImagePath("images/\(UUID().uuidString).png"))
    }

    func testTraversalOutOfTheImagesDirectoryIsRejected() {
        // resolveImagePath appends whatever components it is handed, so a corrupt
        // or hand-edited registry could otherwise aim a delete anywhere.
        let id = UUID().uuidString
        XCTAssertFalse(PreparedCaptureLeaseRegistry
            .isDeletableImagePath("images/../\(id).png"))
        XCTAssertFalse(PreparedCaptureLeaseRegistry
            .isDeletableImagePath("../../\(id).png"))
        XCTAssertFalse(PreparedCaptureLeaseRegistry
            .isDeletableImagePath("images/nested/\(id).png"))
    }

    func testNonGeneratedFilenamesAreRejected() {
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isDeletableImagePath("images/comments.json"))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isDeletableImagePath("images/not-a-uuid.png"))
        XCTAssertFalse(PreparedCaptureLeaseRegistry
            .isDeletableImagePath("images/\(UUID().uuidString).jpg"))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isDeletableImagePath("comments.json"))
    }

    // MARK: - Registry round trip

    func testRecordAndReleaseRoundTrip() throws {
        let path = "images/\(UUID().uuidString).png"
        try PreparedCaptureLeaseRegistry.record(path: path)
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().contains { $0.path == path })

        try PreparedCaptureLeaseRegistry.release(path: path)
        XCTAssertFalse(PreparedCaptureLeaseRegistry.currentLeases().contains { $0.path == path })
    }

    func testRecordingTheSamePathTwiceKeepsOneEntry() throws {
        let path = "images/\(UUID().uuidString).png"
        try PreparedCaptureLeaseRegistry.record(path: path)
        try PreparedCaptureLeaseRegistry.record(path: path)
        let matching = PreparedCaptureLeaseRegistry.currentLeases().filter { $0.path == path }
        XCTAssertEqual(matching.count, 1)
        try PreparedCaptureLeaseRegistry.release(path: path)
    }

    // MARK: - Reconciliation

    func testALiveOwnersFileIsNeverReclaimed() throws {
        // The round-4 hazard: another instance reclaims an in-flight transaction's
        // PNG, sees nothing referencing it, deletes it, and the original process
        // then creates a comment pointing at a missing file.
        let path = "images/\(UUID().uuidString).png"
        let url = resolveImagePath(path)
        try Data("png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try PreparedCaptureLeaseRegistry.record(path: path)
        defer { try? PreparedCaptureLeaseRegistry.release(path: path) }

        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }

        XCTAssertTrue(result.keptLive.contains(path))
        XCTAssertFalse(result.deleted.contains(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a live owner's prepared file must survive")
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().contains { $0.path == path })
    }

    func testACrashLeftoverIsDeletedAndDropped() throws {
        let path = "images/\(UUID().uuidString).png"
        let url = resolveImagePath(path)
        try Data("png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try writeRawLeases([lease(path, pid: 99_999)])
        defer { try? PreparedCaptureLeaseRegistry.release(path: path) }

        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }

        XCTAssertTrue(result.deleted.contains(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.currentLeases().contains { $0.path == path })
    }

    func testAReferencedFileSurvivesEvenWhenItsOwnerDied() throws {
        // The owner died after the comment landed. The file is real and
        // referenced; only the bookkeeping is stale.
        let path = "images/\(UUID().uuidString).png"
        let url = resolveImagePath(path)
        try Data("png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try writeRawLeases([lease(path, pid: 99_999)])
        defer { try? PreparedCaptureLeaseRegistry.release(path: path) }

        let result = PreparedCaptureLeaseRegistry.reconcile { $0 == path }

        XCTAssertTrue(result.keptReferenced.contains(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.currentLeases().contains { $0.path == path },
                       "the lease is dropped, the file is not")
    }

    func testAnUnleasedFileIsNeverTouched() throws {
        // Stands in for a retained orphan or a draft-held attachment: on disk,
        // unreferenced, and not in the registry.
        let path = "images/\(UUID().uuidString).png"
        let url = resolveImagePath(path)
        try Data("png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }

        XCTAssertFalse(result.deleted.contains(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "reconciliation must never enumerate the images directory")
    }

    func testACorruptRegistryPathIsRejectedNotDeleted() throws {
        try writeRawLeases([lease("images/../../../../../../tmp/remarc-lease-probe.png",
                                  pid: 99_999)])
        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(result.deleted, [])
        XCTAssertEqual(result.rejectedPath.count, 1)
    }

    // MARK: - Helper

    /// Writes leases straight into the registry, so a dead-owner lease can be
    /// staged without a second process.
    private func writeRawLeases(_ leases: [PreparedCaptureLease]) throws {
        let existing = PreparedCaptureLeaseRegistry.currentLeases()
        let data = try JSONEncoder().encode(existing + leases)
        try data.write(to: PreparedCaptureLeaseRegistry.registryURL, options: .atomic)
    }
}
