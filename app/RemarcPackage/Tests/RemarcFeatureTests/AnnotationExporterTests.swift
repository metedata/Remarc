import XCTest
import AppKit
@testable import RemarcFeature

/// The preview panel's Apply action, which permanently replaces an app-owned PNG.
final class AnnotationExporterTests: XCTestCase {

    private var written: [String] = []

    override func tearDownWithError() throws {
        for path in written {
            try? FileManager.default.removeItem(at: resolveImagePath(path))
        }
        written.removeAll()
    }

    private func makeStoredImage(width: Int = 40, height: Int = 30) throws -> String {
        let image = TestImages.solid(width: width, height: height, red: 1, green: 0, blue: 0)
        let path = try AnnotationExporter.writeNewImage(image)
        written.append(path)
        return path
    }

    // MARK: - Encoding

    /// `NSImage.pngData()`, the app's existing encoder, round-trips through TIFF and
    /// through `NSImage.size`, which is in POINTS. A Retina composite comes back at
    /// half its pixel dimensions.
    func testEncodingPreservesExactPixelDimensions() throws {
        let image = TestImages.solid(width: 401, height: 161, red: 0, green: 1, blue: 0)
        let data = try AnnotationExporter.pngData(from: image)
        let decoded = NSBitmapImageRep(data: data)
        XCTAssertEqual(decoded?.pixelsWide, 401)
        XCTAssertEqual(decoded?.pixelsHigh, 161)
    }

    // MARK: - Decoding

    func testDecodeReturnsExactPixelDimensions() throws {
        let path = try makeStoredImage(width: 77, height: 53)
        let decoded = AnnotationExporter.decode(relativePath: path)
        XCTAssertEqual(decoded?.width, 77)
        XCTAssertEqual(decoded?.height, 53)
    }

    func testDecodingAMissingPathReturnsNilRatherThanCrashing() {
        XCTAssertNil(AnnotationExporter.decode(relativePath: "images/\(UUID().uuidString).png"))
    }

    // MARK: - Owned-path replacement

    func testApplyReplacesTheBytesAtTheSamePath() throws {
        let path = try makeStoredImage()
        let before = try Data(contentsOf: resolveImagePath(path))

        let replacement = TestImages.solid(width: 40, height: 30, red: 0, green: 0, blue: 1)
        try AnnotationExporter.replaceOwnedImage(at: path, with: replacement)

        let after = try Data(contentsOf: resolveImagePath(path))
        XCTAssertNotEqual(before, after, "Apply must actually change the stored bytes")

        let reloaded = AnnotationExporter.decode(relativePath: path)
        XCTAssertNotNil(reloaded)
        let px = TestImages.pixel(reloaded!, x: 20, y: 15)
        XCTAssertGreaterThan(px[2], 200, "the blue replacement is on disk")
        XCTAssertLessThan(px[0], 60)
    }

    /// Only beneath `Remarc/images`. Both sides are resolved through
    /// `standardizedFileURL` and `resolvingSymlinksInPath()` first, so `..` lands on
    /// the real path rather than on a string that merely looks contained.
    func testReplacementOutsideTheImagesDirectoryIsRefused() throws {
        let probe = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remarc-escape-\(UUID().uuidString).png")
        try Data("original".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        let escaping = "images/../../../../../../../../\(probe.path.dropFirst())"
        let image = TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0)

        XCTAssertThrowsError(
            try AnnotationExporter.replaceOwnedImage(at: escaping, with: image)
        ) { error in
            guard case AnnotationExporter.ExportError.notOwnedPath = error else {
                return XCTFail("expected notOwnedPath, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: probe), Data("original".utf8),
                       "the file outside the images directory must be untouched")
    }

    func testANestedPathBeneathImagesIsAlsoRefused() {
        // Strict descendancy: a direct child only, matching what the app generates.
        let image = TestImages.solid(width: 8, height: 8, red: 1, green: 1, blue: 1)
        XCTAssertThrowsError(try AnnotationExporter.replaceOwnedImage(
            at: "images/nested/\(UUID().uuidString).png", with: image))
    }

    // MARK: - Revision signal

    @MainActor
    func testRevisionBumpsMonotonicallyPerPath() {
        let center = StoredImageRevisionCenter.shared
        let a = "images/\(UUID().uuidString).png"
        let b = "images/\(UUID().uuidString).png"

        let a0 = center.revision(for: a)
        center.bump(a)
        XCTAssertEqual(center.revision(for: a), a0 + 1)
        center.bump(a)
        XCTAssertEqual(center.revision(for: a), a0 + 2)

        XCTAssertEqual(center.revision(for: b), 0,
                       "bumping one path must not disturb another")
    }
}
