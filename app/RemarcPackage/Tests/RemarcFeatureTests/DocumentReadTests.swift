import XCTest
@testable import RemarcFeature

/// Both save paths merged against the in-memory snapshot whenever the file on
/// disk failed to decode, then wrote the result - so a document written by a
/// newer build was replaced by whatever this build was holding. The distinction
/// this covers is the one that was missing: absent is safe to write, unreadable
/// is not ours to overwrite.
final class DocumentReadTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "remarc-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "comments.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileReadsAsAbsent() {
        guard case .absent = DocumentRead.read(file) else {
            return XCTFail("a file that does not exist is not a corrupt one")
        }
    }

    func testValidDocumentDecodes() throws {
        try JSONEncoder().encode(AppState(totalCommentsCreated: 4)).write(to: file)
        guard case .decoded(let state) = DocumentRead.read(file) else {
            return XCTFail("expected a decoded document")
        }
        XCTAssertEqual(state.totalCommentsCreated, 4)
    }

    func testGarbageIsUnreadableRatherThanEmpty() throws {
        try Data("not json at all".utf8).write(to: file)
        guard case .unreadable = DocumentRead.read(file) else {
            return XCTFail("undecodable content must not be treated as absent")
        }
    }

    /// A zero-byte file is a truncated write, not a fresh start. Reading it as
    /// absent is exactly what turns a crash mid-write into a wipe.
    func testEmptyFileIsUnreadableRatherThanAbsent() throws {
        try Data().write(to: file)
        guard case .unreadable = DocumentRead.read(file) else {
            return XCTFail("an empty file must not license overwriting it")
        }
    }

    /// Refusing to write protects the file but strands unsaved work, so it has
    /// to land somewhere the user can get at it.
    func testRecoveryDumpIsWrittenBesideTheFile() throws {
        DocumentRecovery.dump(
            AppState(totalCommentsCreated: 11), beside: file, reason: "test"
        )
        let dumps = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("comments.recovered-") }
        XCTAssertEqual(dumps.count, 1)

        let data = try Data(contentsOf: dir.appending(path: try XCTUnwrap(dumps.first)))
        let recovered = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(recovered.totalCommentsCreated, 11)
    }
}
