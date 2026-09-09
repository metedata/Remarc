import XCTest
import AppKit
@testable import RemarcFeature

@MainActor
final class ScreenshotStorageExportTests: XCTestCase {
    private var storage = TemporaryStorageRoot()

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
    }

    override func tearDown() async throws {
        storage.remove()
    }

    func testDefaultScreenshotsAndPastedAttachmentsExportReadableAbsolutePaths() throws {
        let session = Session(name: "Default storage")
        let comments = try makeComments(session: session)
        XCTAssertTrue(try XCTUnwrap(comments[0].type.imagePath).hasPrefix("images/"))
        XCTAssertTrue(try XCTUnwrap(comments[1].attachments.first).hasPrefix("images/"))

        try assertExport(comments, session: session, directory: ScreenshotStorage.defaultDirectory)
    }

    func testCustomFolderWithSpacesAndParenthesesSurvivesExport() throws {
        let directory = try chooseFolder("Design review (screenshots)")
        let session = Session(name: "Custom storage")
        let comments = try makeComments(session: session)
        XCTAssertTrue(try XCTUnwrap(comments[0].type.imagePath).hasPrefix(directory.path + "/"))
        XCTAssertTrue(try XCTUnwrap(comments[1].attachments.first).hasPrefix(directory.path + "/"))

        try assertExport(comments, session: session, directory: directory)
    }

    func testMarkdownDelimitersAndUnicodeRoundTripToReadableImages() throws {
        let directory = try chooseFolder("Design [v1] (final) <tag> #?%20\\\nMété 日本")
        let session = Session(name: "Unusual folder characters")
        let comments = try makeComments(session: session)

        try assertExport(comments, session: session, directory: directory)
    }

    func testWebhookPayloadPreservesCustomScreenshotAndAttachmentPaths() throws {
        _ = try chooseFolder("Design review (Mété 日本) #percent%")
        let session = Session(name: "Webhook storage")
        let comments = try makeComments(session: session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for comment in comments {
            let body = WebhookService.buildDefaultBody(
                event: .commentCreated, comment: comment, sessionName: session.name,
                sessionID: session.id, timestamp: Date(), appVersion: "test")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let serialized = try JSONSerialization.data(withJSONObject: XCTUnwrap(payload["comment"]))
            let delivered = try decoder.decode(RemarcFeature.Comment.self, from: serialized)
            XCTAssertEqual(delivered.type, comment.type)
            XCTAssertEqual(delivered.attachments, comment.attachments)
            for path in (delivered.type.imagePath.map { [$0] } ?? []) + delivered.attachments {
                XCTAssertTrue(path.hasPrefix("/"))
                XCTAssertNotNil(NSImage(contentsOfFile: path))
            }
        }
    }

    func testChangingAndResettingFolderDoesNotRedirectExportedReferences() throws {
        let session = Session(name: "Mixed storage")
        let original = try makeComments(session: session)
        let firstDirectory = try chooseFolder("First folder (review)")
        let first = try makeComments(session: session)
        let secondDirectory = try chooseFolder("Second folder (final)")
        let second = try makeComments(session: session)

        try assertExport(original, session: session, directory: ScreenshotStorage.defaultDirectory)
        try assertExport(first, session: session, directory: firstDirectory)
        try assertExport(second, session: session, directory: secondDirectory)

        try ScreenshotStorage.configure(directory: nil, defaults: storage.defaults)
        let reset = try makeComments(session: session)
        XCTAssertTrue(try XCTUnwrap(reset[0].type.imagePath).hasPrefix("images/"))
        try assertExport(original, session: session, directory: ScreenshotStorage.defaultDirectory)
        try assertExport(first, session: session, directory: firstDirectory)
        try assertExport(second, session: session, directory: secondDirectory)
        try assertExport(reset, session: session, directory: ScreenshotStorage.defaultDirectory)
    }

    private func chooseFolder(_ name: String) throws -> URL {
        let directory = storage.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = try ScreenshotStorage.configure(directory: directory, defaults: storage.defaults)
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }

    private func makeComments(session: Session) throws -> [RemarcFeature.Comment] {
        let image = TestImages.solid(width: 8, height: 8, red: 0, green: 1, blue: 0)
        let screenshot = try AnnotationExporter.writeNewImage(image)
        // Pasted images use this same storage writer after PNG conversion.
        // Keep the test isolated from PersistenceManager's live data singleton.
        let attachment = try writeNewScreenshotData(AnnotationExporter.pngData(from: image))
        return [
            RemarcFeature.Comment(
                type: .screenshot(imagePath: screenshot), commentText: "Review the image",
                source: "Screenshot", appBundleID: nil, sessionID: session.id,
                attachments: [attachment]),
            RemarcFeature.Comment(
                type: .quickNote, commentText: "Review this pasted attachment",
                source: "Remarc", appBundleID: nil, sessionID: session.id,
                attachments: [attachment])
        ]
    }

    private func assertExport(
        _ comments: [RemarcFeature.Comment], session: Session, directory: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let markdown = ExportManager.shared.markdownForComments(
            comments, referenceStyle: .blockquote, numberingStyle: .none,
            dividerStyle: .horizontalRule, dateFormat: .iso,
            includeRemarkID: false, includeSource: false, includeDate: false,
            includeStatus: false, includeType: false)
        // Parse the whole export, rather than comparing against another copy
        // of the formatter. Every image must still resolve to its actual PNG.
        let parsed = try AttributedString(markdown: markdown)
        let imageURLs = parsed.runs.compactMap(\.imageURL)
        let expectedPaths = comments.flatMap { comment in
            (comment.type.imagePath.map { [$0] } ?? []) + comment.attachments
        }.map { resolveImagePath($0).path }
        XCTAssertEqual(imageURLs.map { $0.path(percentEncoded: false) }, expectedPaths,
                       file: file, line: line)
        for imageURL in imageURLs {
            XCTAssertNil(imageURL.query, file: file, line: line)
            XCTAssertNil(imageURL.fragment, file: file, line: line)
            let fileURL = URL(fileURLWithPath: imageURL.path(percentEncoded: false))
            XCTAssertNotNil(NSImage(contentsOf: fileURL), "Parsed Markdown must load the saved PNG",
                            file: file, line: line)
        }

        for includeMetadata in [false, true] {
            let json = ExportManager.shared.jsonForSession(
                session, comments: comments, includeMetadata: includeMetadata)
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let rows: [[String: Any]]
            if includeMetadata {
                let wrapper = try XCTUnwrap(object as? [String: Any], file: file, line: line)
                XCTAssertEqual(wrapper["session"] as? String, session.name, file: file, line: line)
                rows = try XCTUnwrap(wrapper["comments"] as? [[String: Any]], file: file, line: line)
            } else {
                rows = try XCTUnwrap(object as? [[String: Any]], file: file, line: line)
            }
            XCTAssertEqual(rows.count, comments.count, file: file, line: line)
            for (row, comment) in zip(rows, comments) {
                let expectedScreenshot = comment.type.imagePath.map { resolveImagePath($0).path }
                XCTAssertEqual(row["imagePath"] as? String, expectedScreenshot, file: file, line: line)
                let attachments = try XCTUnwrap(row["attachments"] as? [String], file: file, line: line)
                XCTAssertEqual(attachments, comment.attachments.map { resolveImagePath($0).path }, file: file, line: line)
                let paths = attachments + (expectedScreenshot.map { [$0] } ?? [])
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    XCTAssertTrue(path.hasPrefix("/"), file: file, line: line)
                    XCTAssertEqual(url.deletingLastPathComponent().path, directory.path, file: file, line: line)
                    XCTAssertNotNil(NSImage(contentsOf: url), "Exported path must load the saved PNG", file: file, line: line)
                }
            }
        }
    }
}
