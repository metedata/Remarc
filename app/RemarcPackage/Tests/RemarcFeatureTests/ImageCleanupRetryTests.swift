import Foundation
import XCTest
@testable import RemarcFeature

@MainActor
final class ImageCleanupRetryTests: XCTestCase {
    private var storage = TemporaryStorageRoot()

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
    }

    override func tearDown() async throws {
        storage.remove()
    }

    func testAbandonedLeaseSurvivesUnavailableFolderAndReclaimsAfterReturn() throws {
        let directory = try configureCustomDirectory()
        let path = try writeNewScreenshotData(Data("capture".utf8))
        try recordAbandonedLease(path)
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)

        let unavailable = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(unavailable.keptFailed, [path])
        XCTAssertTrue(unavailable.deleted.isEmpty)
        XCTAssertEqual(PreparedCaptureLeaseRegistry.currentLeases().map(\.path), [path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.moveItem(at: offline, to: directory)
        let reconnected = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(reconnected.deleted, [path])
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testPartialFamilyDeletionPreservesLeaseUntilSidecarsCanBeRemoved() throws {
        let path = try writeNewScreenshotData(Data("capture".utf8))
        let outside = storage.url.appendingPathComponent("unrelated.png")
        try Data("unrelated".utf8).write(to: outside)
        let sidecar = resolveImagePath(AnnotationMarkStore.basePath(for: path))
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        try recordAbandonedLease(path)

        let partial = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(partial.keptFailed, [path])
        XCTAssertTrue(partial.deleted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("unrelated".utf8))
        XCTAssertEqual(PreparedCaptureLeaseRegistry.currentLeases().map(\.path), [path])

        // Removing the invalid link allows cleanup to finish even though its
        // primary PNG was already removed by the first attempt.
        try FileManager.default.removeItem(at: sidecar)
        let retried = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(retried.deleted, [path])
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("unrelated".utf8))
    }

    func testRetentionKeepsUnavailableExpiredFilesAndUnexpiredFiles() throws {
        let available = try writeNewScreenshotData(Data("expired".utf8))
        let recent = try writeNewScreenshotData(Data("recent".utf8))
        let directory = try configureCustomDirectory()
        let unavailable = try writeNewScreenshotData(Data("offline".utf8))
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        let cutoff = Date()
        var orphans = [
            OrphanedImage(path: available, deletedAt: .distantPast),
            OrphanedImage(path: unavailable, deletedAt: .distantPast),
            OrphanedImage(path: recent, deletedAt: .distantFuture),
        ]

        PersistenceManager.pruneExpiredImages(&orphans, before: cutoff)
        XCTAssertEqual(orphans.map(\.path), [unavailable, recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(available).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(recent).path))

        try FileManager.default.moveItem(at: offline, to: directory)
        PersistenceManager.pruneExpiredImages(&orphans, before: cutoff)
        XCTAssertEqual(orphans.map(\.path), [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(recent).path))
    }

    func testPermanentDeletionQueuesOneImmediateRetryAndPreservesItsIdentity() throws {
        let directory = try configureCustomDirectory()
        let path = try writeNewScreenshotData(Data("capture".utf8))
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        let original = OrphanedImage(path: path, deletedAt: Date())
        var orphans = [original]

        PersistenceManager.deleteImageOrRetainForRetry(path, orphanedImages: &orphans)
        PersistenceManager.deleteImageOrRetainForRetry(path, orphanedImages: &orphans)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.id, original.id)
        XCTAssertEqual(orphans.first?.deletedAt, Date.distantPast)

        try FileManager.default.moveItem(at: offline, to: directory)
        let retentionCutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        PersistenceManager.pruneExpiredImages(&orphans, before: retentionCutoff)
        XCTAssertTrue(orphans.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAnAlreadyMissingFileInAnAvailableFolderCompletesCleanup() throws {
        let path = "images/\(UUID().uuidString).png"
        try recordAbandonedLease(path)

        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(result.deleted, [path])
        XCTAssertTrue(result.keptFailed.isEmpty)
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
    }

    private func configureCustomDirectory() throws -> URL {
        let directory = storage.url.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ScreenshotStorage.configure(directory: directory, defaults: remarcScreenshotDefaults)
        return directory
    }

    private func recordAbandonedLease(_ path: String) throws {
        let lease = PreparedCaptureLease(path: path, pid: 99_999,
                                         bootTime: -1, startTime: -1, at: 0)
        try JSONEncoder().encode([lease]).write(to: PreparedCaptureLeaseRegistry.registryURL, options: .atomic)
    }
}
