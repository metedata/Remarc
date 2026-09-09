import XCTest
import AppKit
@testable import RemarcFeature

final class ImageStoragePathTests: XCTestCase {

    private var root: TemporaryStorageRoot!

    override func setUpWithError() throws {
        root = TemporaryStorageRoot()
        try root.install()
    }

    override func tearDownWithError() throws {
        root.remove()
        root = nil
    }

    func testDefaultWriteUsesRelativePathUnderAppSupport() throws {
        let path = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 1, green: 0, blue: 0))
        XCTAssertTrue(path.hasPrefix("images/"))
        XCTAssertFalse(path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
        XCTAssertEqual(resolveImagePath(path).deletingLastPathComponent().path,
                       remarcAppSupportURL.appendingPathComponent("images").path)
    }

    func testCustomDirectoryStoresAbsolutePathsAgentsCanOpen() throws {
        let custom = try makeCustomDirectory()
        let path = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0))
        XCTAssertTrue(path.hasPrefix(custom.path))
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertEqual(resolveImagePath(path).path, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCustomDirectoryReplaceAndRelativeFallbackStayOwned() throws {
        let custom = try makeCustomDirectory()
        let customPath = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 1, green: 0, blue: 0))

        let replacement = TestImages.solid(width: 8, height: 8, red: 0, green: 0, blue: 1)
        try AnnotationExporter.replaceOwnedImage(at: customPath, with: replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customPath))

        UserDefaults.standard.removeObject(forKey: remarcScreenshotDirectoryPathKey)
        let relative = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0))
        XCTAssertTrue(relative.hasPrefix("images/"))

        UserDefaults.standard.set(custom.path, forKey: remarcScreenshotDirectoryPathKey)
        try AnnotationExporter.replaceOwnedImage(at: relative, with: replacement)
    }

    func testPreviousCustomPathStaysOwnedAfterTheSettingMoves() throws {
        let first = try makeCustomDirectory(name: "shots-a")
        let path = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 1, green: 0, blue: 0))
        XCTAssertTrue(path.hasPrefix(first.path))

        _ = try makeCustomDirectory(name: "shots-b")
        XCTAssertNotNil(remarcOwnedImageURL(for: path))
        try AnnotationExporter.replaceOwnedImage(
            at: path,
            with: TestImages.solid(width: 8, height: 8, red: 0, green: 0, blue: 1))
        XCTAssertTrue(PreparedCaptureLeaseRegistry.isDeletableImagePath(path))
    }

    func testTraversalIsStillRefusedWithACustomDirectory() throws {
        _ = try makeCustomDirectory()
        let probe = root.url.appendingPathComponent("escape-\(UUID().uuidString).png")
        try Data("original".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        let escaping = "images/../../../../../../../../\(probe.path.dropFirst())"
        XCTAssertThrowsError(
            try AnnotationExporter.replaceOwnedImage(
                at: escaping,
                with: TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0))
        ) { error in
            guard case AnnotationExporter.ExportError.notOwnedPath = error else {
                return XCTFail("expected notOwnedPath, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: probe), Data("original".utf8))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isDeletableImagePath(escaping))
    }

    private func makeCustomDirectory(name: String = "custom-shots") throws -> URL {
        let custom = root.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        UserDefaults.standard.set(custom.path, forKey: remarcScreenshotDirectoryPathKey)
        return custom
    }
}
