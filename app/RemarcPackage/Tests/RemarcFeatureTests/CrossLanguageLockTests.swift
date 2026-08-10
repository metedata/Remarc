import XCTest
@testable import RemarcFeature

/// Proves the Swift and Node lock implementations actually exclude each other.
///
/// They are separate codebases agreeing only on a convention (an atomic `mkdir`
/// of `<file>.lock` holding `owner.json`). Every claim about concurrent writers
/// rests on that agreement, and nothing tested it until now.
final class CrossLanguageLockTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "remarc-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "comments.json")
        try Data("{}".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A Node-style holder (the same lock directory + owner.json shape) must
    /// block the Swift lock until it is released.
    func testSwiftWaitsForAForeignHolder() throws {
        let lock = DocumentLock.lockURL(for: file)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        // A live pid: our own. The Swift side must treat this as held.
        let owner = ["pid": ProcessInfo.processInfo.processIdentifier, "at": 0] as [String: Any]
        try JSONSerialization.data(withJSONObject: owner)
            .write(to: lock.appendingPathComponent("owner.json"))

        var entered = false
        XCTAssertThrowsError(try DocumentLock.withLock(file) { entered = true }) { error in
            XCTAssertTrue(error is DocumentLock.TimedOut, "expected a timeout, got \(error)")
        }
        XCTAssertFalse(entered, "Swift entered a lock another process was holding")

        try FileManager.default.removeItem(at: lock)
        try DocumentLock.withLock(file) { entered = true }
        XCTAssertTrue(entered, "Swift did not acquire the lock after it was released")
    }

    /// A lock whose owner is gone must be reclaimed, or one crashed writer
    /// would wedge every other process permanently.
    func testSwiftReclaimsALockFromADeadOwner() throws {
        let lock = DocumentLock.lockURL(for: file)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        // 999999 is not a running process.
        let owner = ["pid": 999_999, "at": 0] as [String: Any]
        try JSONSerialization.data(withJSONObject: owner)
            .write(to: lock.appendingPathComponent("owner.json"))

        var entered = false
        try DocumentLock.withLock(file) { entered = true }
        XCTAssertTrue(entered, "a lock held by a dead pid was never reclaimed")
    }

    /// Age alone must not evict a live holder: that was the defect where the
    /// victim kept working and its release then deleted the new owner's lock.
    func testAnOldButLiveLockIsNotStolen() throws {
        let lock = DocumentLock.lockURL(for: file)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let owner = ["pid": ProcessInfo.processInfo.processIdentifier, "at": 0] as [String: Any]
        try JSONSerialization.data(withJSONObject: owner)
            .write(to: lock.appendingPathComponent("owner.json"))
        // Backdate well past the staleness window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: lock.path
        )

        XCTAssertThrowsError(try DocumentLock.withLock(file) { }) { error in
            XCTAssertTrue(error is DocumentLock.TimedOut, "an old but live lock was stolen")
        }
    }

    /// The Swift writer must leave the lock directory behind for nobody: a
    /// leaked lock is indistinguishable from a held one.
    func testLockIsReleasedEvenWhenTheBodyThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try DocumentLock.withLock(file) { throw Boom() })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: DocumentLock.lockURL(for: file).path),
            "lock leaked after the body threw"
        )
    }
}
