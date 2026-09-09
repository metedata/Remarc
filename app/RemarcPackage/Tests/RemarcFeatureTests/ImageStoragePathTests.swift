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

        try ScreenshotStorage.configure(directory: nil, defaults: root.defaults)
        let relative = try AnnotationExporter.writeNewImage(
            TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0))
        XCTAssertTrue(relative.hasPrefix("images/"))

        try ScreenshotStorage.configure(directory: custom, defaults: root.defaults)
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

    func testUUIDOutsideKnownFoldersCannotBeOverwrittenOrDeleted() throws {
        _ = try makeCustomDirectory()
        let outside = root.url.appendingPathComponent("\(UUID().uuidString).png")
        let original = Data("unrelated image".utf8)
        try original.write(to: outside)
        XCTAssertNil(remarcOwnedImageURL(for: outside.path))
        XCTAssertThrowsError(try AnnotationExporter.replaceOwnedData(Data(), at: outside.path))
        XCTAssertThrowsError(try AnnotationMarkStore.deleteImageFamily(outside.path))
        XCTAssertFalse(PreparedCaptureLeaseRegistry.isDeletableImagePath(outside.path))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testCustomFolderDoesNotOwnUnrelatedFilesOrDirectories() throws {
        let custom = try makeCustomDirectory()
        for name in ["design.base.png", "design.marks.json", "notes.txt"] {
            let file = custom.appendingPathComponent(name)
            try Data("keep".utf8).write(to: file)
            XCTAssertNil(remarcOwnedImageURL(for: file.path))
        }
        XCTAssertEqual(AnnotationMarkStore.removeOrphanedSidecars(), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: custom.path).count, 3)
    }

    func testHistorySweepsOnlyManagedSidecarsAfterReset() throws {
        let first = try makeCustomDirectory(name: "Shots A (project)")
        let orphanID = UUID().uuidString
        for suffix in [".base.png", ".marks.json"] {
            try Data("orphan".utf8).write(to: first.appendingPathComponent(orphanID + suffix))
        }
        _ = try makeCustomDirectory(name: "Shots B")
        try ScreenshotStorage.configure(directory: nil, defaults: root.defaults)
        XCTAssertEqual(AnnotationMarkStore.removeOrphanedSidecars(), 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
    }

    func testAnnotationFamilyRemainsEditableAfterFolderChanges() throws {
        _ = try makeCustomDirectory(name: "Shots A")
        let image = TestImages.solid(width: 20, height: 20, red: 1, green: 0, blue: 0)
        let path = try AnnotationExporter.writeNewImage(image)
        let mark = AnnotationItem(payload: .arrow(from: CGPoint(x: 1, y: 1),
                                                 to: CGPoint(x: 15, y: 15), style: .straight),
                                  ink: AnnotationInk(red: 0, green: 1, blue: 0), strokeWidth: 2)
        try AnnotationMarkStore.write(base: image, items: [mark],
                                      flattenedPNG: Data(contentsOf: resolveImagePath(path)), for: path)
        _ = try makeCustomDirectory(name: "Shots B")
        try ScreenshotStorage.configure(directory: nil, defaults: root.defaults)
        XCTAssertEqual(AnnotationMarkStore.restore(for: path)?.items.first?.id, mark.id)
        XCTAssertEqual(AnnotationMarkStore.removeOrphanedSidecars(), 0)
        try AnnotationMarkStore.deleteImageFamily(path)
        for file in [path, AnnotationMarkStore.basePath(for: path), AnnotationMarkStore.marksPath(for: path)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(file).path))
        }
    }

    func testFileSymlinkCannotEscapeOrOverwriteAnotherManagedImage() throws {
        let first = try makeCustomDirectory(name: "first")
        let outside = root.url.appendingPathComponent("\(UUID().uuidString).png")
        try Data("keep".utf8).write(to: outside)
        let link = first.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(remarcOwnedImageURL(for: link.path))
        XCTAssertThrowsError(try AnnotationMarkStore.deleteImageFamily(link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))

        let second = try makeCustomDirectory(name: "second")
        let owned = second.appendingPathComponent("\(UUID().uuidString).png")
        try Data("owned elsewhere".utf8).write(to: owned)
        let ownedLink = first.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: ownedLink, withDestinationURL: owned)
        XCTAssertNil(remarcOwnedImageURL(for: ownedLink.path))
    }

    func testHistoricalFolderReplacedBySymlinkDoesNotGrantNewOwnership() throws {
        let first = try makeCustomDirectory(name: "first")
        _ = try makeCustomDirectory(name: "second")
        try FileManager.default.removeItem(at: first)
        let outside = root.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sidecar = outside.appendingPathComponent("\(UUID().uuidString).base.png")
        try Data("keep".utf8).write(to: sidecar)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: outside)
        XCTAssertNil(remarcOwnedImageURL(for: first.appendingPathComponent(sidecar.lastPathComponent).path))
        XCTAssertEqual(AnnotationMarkStore.removeOrphanedSidecars(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testPreviousFolderCannotRedirectWritesToDefaultFolder() throws {
        let first = try makeCustomDirectory(name: "first")
        try ScreenshotStorage.configure(directory: nil, defaults: root.defaults)
        let path = try writeNewScreenshotData(Data("keep default".utf8))
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: ScreenshotStorage.defaultDirectory)
        let redirected = first.appendingPathComponent(resolveImagePath(path).lastPathComponent).path
        XCTAssertNil(remarcOwnedImageURL(for: redirected))
        XCTAssertThrowsError(try AnnotationMarkStore.deleteImageFamily(redirected))
        XCTAssertEqual(try Data(contentsOf: resolveImagePath(path)), Data("keep default".utf8))
    }

    func testUUIDNamedDirectoryIsNeverDeletedRecursively() throws {
        let custom = try makeCustomDirectory()
        let folder = custom.appendingPathComponent("\(UUID().uuidString).png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: document)
        XCTAssertThrowsError(try AnnotationMarkStore.deleteImageFamily(folder.path))
        XCTAssertEqual(try Data(contentsOf: document), Data("keep".utf8))
    }

    func testInvalidChoicePreservesSettingAndMissingCustomFolderDoesNotFallback() throws {
        let current = try makeCustomDirectory()
        let oldHistory = root.defaults.stringArray(forKey: ScreenshotStorage.knownDirectoriesKey)
        let invalid = root.url.appendingPathComponent("ordinary-file")
        try Data().write(to: invalid)
        XCTAssertThrowsError(try ScreenshotStorage.configure(directory: invalid, defaults: root.defaults))
        XCTAssertEqual(root.defaults.string(forKey: remarcScreenshotDirectoryPathKey), current.path)
        XCTAssertEqual(root.defaults.stringArray(forKey: ScreenshotStorage.knownDirectoriesKey), oldHistory)
        try FileManager.default.removeItem(at: current)
        XCTAssertThrowsError(try writeNewScreenshotData(Data("image".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ScreenshotStorage.defaultDirectory.path).isEmpty)
    }

    func testSelectingDefaultAliasClearsCustomSetting() throws {
        _ = try makeCustomDirectory()
        let alias = root.url.appendingPathComponent("default-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ScreenshotStorage.defaultDirectory)
        XCTAssertEqual(try ScreenshotStorage.configure(directory: alias, defaults: root.defaults), "")
        XCTAssertNil(root.defaults.string(forKey: remarcScreenshotDirectoryPathKey))
        XCTAssertTrue(try writeNewScreenshotData(Data()).hasPrefix("images/"))
    }

    private func makeCustomDirectory(name: String = "custom-shots") throws -> URL {
        let custom = root.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try ScreenshotStorage.configure(directory: custom, defaults: root.defaults)
        return custom.standardizedFileURL.resolvingSymlinksInPath()
    }
}
