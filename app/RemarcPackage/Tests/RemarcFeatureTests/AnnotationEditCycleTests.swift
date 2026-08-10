import XCTest
import AppKit
@testable import RemarcFeature

/// The re-editing round trip, driven through the real controller.
@MainActor
final class AnnotationEditCycleTests: XCTestCase {

    private var storage = TemporaryStorageRoot()

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
    }

    override func tearDown() async throws {
        ScreenshotPreviewController.shared.forceTeardownForTesting()
        storage.remove()
    }

    /// A red field with a finely STRIPED patch standing in for the secret.
    ///
    /// Stripes rather than a solid block on purpose: a redaction of a uniform
    /// region returns that same region, so a solid patch comes through
    /// completely unchanged and a test built on one measures nothing. Structure
    /// is what there is to lose.
    private func storedImage() throws -> String {
        let width = 120, height = 80
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Bottom-left origin in CGContext; source pixels below use a top-left
        // origin, so this occupies y 10..<40 from the top.
        for column in stride(from: 0, to: 60, by: 4) {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 10 + column, y: height - 40, width: 2, height: 30))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 12 + column, y: height - 40, width: 2, height: 30))
        }

        let path = try AnnotationExporter.writeNewImage(ctx.makeImage()!)
        return path
    }

    private let secretRect = CGRect(x: 10, y: 10, width: 60, height: 30)

    private func annotate(_ path: String) throws -> AnnotationSession {
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)
        controller.toggleAnnotationForTesting()
        return try XCTUnwrap(controller.sessionForTesting)
    }

    private func arrow(_ from: CGPoint, _ to: CGPoint) -> AnnotationItem {
        AnnotationItem(payload: .arrow(from: from, to: to, style: .straight),
                       ink: AnnotationInk(red: 0, green: 1, blue: 0), strokeWidth: 4)
    }

    // MARK: - Vectors survive

    func testVectorMarksComeBackEditableOnTheNextAnnotate() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        let originalID = try XCTUnwrap(session.items.first).id
        await controller.applyAnnotationsForTesting()
        XCTAssertFalse(controller.isAnnotating)

        // Reopen.
        let second = try annotate(path)
        XCTAssertEqual(second.items.count, 1, "the arrow must come back as a mark, not as pixels")
        XCTAssertEqual(second.items.first?.id, originalID, "identity survives the round trip")
        XCTAssertFalse(second.isDirty, "reopening is not an edit")
        XCTAssertFalse(second.canUndo, "history starts at the loaded state")
    }

    func testAReopenedMarkCanBeDeletedAndTheImageLosesIt() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        let withMark = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
        let greenBefore = Self.greenPixelCount(withMark)
        XCTAssertGreaterThan(greenBefore, 0)

        let second = try annotate(path)
        second.selectedItemID = try XCTUnwrap(second.items.first).id
        second.deleteSelected()
        XCTAssertTrue(second.items.isEmpty)
        await controller.applyAnnotationsForTesting()

        let withoutMark = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
        XCTAssertEqual(Self.greenPixelCount(withoutMark), 0,
                       "deleting a restored mark must remove it from the stored image")
    }

    // MARK: - Redactions are permanent

    /// The privacy contract this change is responsible for: Apply must not
    /// leave a pristine capture beside the obscured copy. The stored base has
    /// to carry the redaction too.
    ///
    /// Named for what it proves. It asserts the base agrees with the visible
    /// image and differs from the capture - not that the content is
    /// unrecoverable, which is a stronger claim than obscuration filters make.
    ///
    /// Asserted two ways. The region comparison is the contract itself and does
    /// not care how good the filter is: the base must carry the redaction, not a
    /// pristine capture. The stripe count then confirms the filter actually
    /// destroyed the structure, so the first assertion cannot pass on a
    /// redaction that changed a single pixel.
    func testNoPristineCaptureIsKeptBesideTheRedactedCopy() async throws {
        // Both filters get the same budget, because both are now destructive.
        // CIPixellate on its own point-samples each cell's centre rather than
        // averaging it, which left 26.7% of the region's pixels holding their
        // exact original values - measured, and it failed this assertion. The
        // filter blurs by half a cell before forming the cells for that reason,
        // which takes it to 0%.
        for (redaction, survivalBudget) in [(AnnotationPayload.blur(secretRect), 0.05),
                                            (.pixelate(secretRect), 0.05)] {
            let path = try storedImage()
            let controller = ScreenshotPreviewController.shared

            let original = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
            let originalRegion = Self.region(original, secretRect)
            XCTAssertGreaterThan(Self.stripeEdges(original, secretRect), 20,
                                 "the fixture must carry recoverable structure to begin with")

            let session = try annotate(path)
            session.add(AnnotationItem(payload: redaction,
                                       ink: AnnotationInk.presets[0], strokeWidth: 1))
            session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
            await controller.applyAnnotationsForTesting()

            let flattened = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
            let base = try XCTUnwrap(
                AnnotationExporter.decode(relativePath: AnnotationMarkStore.basePath(for: path)),
                "a base must exist: the arrow is still editable")

            XCTAssertNotEqual(Self.region(base, secretRect), originalRegion,
                              "\(redaction): the stored base is still the untouched capture")
            XCTAssertEqual(Self.region(base, secretRect), Self.region(flattened, secretRect),
                           "\(redaction): the base and the visible image must agree on the redaction")

            // Per-pixel survival, not an edge count. Counting edges measures the
            // wrong thing for pixelate: a 60x30 region gets a 6px cell, the
            // fixture's stripes have a 4px period, and the two beat against each
            // other at period 12. Those residual edges are artifacts OF the
            // pixelation, not original detail coming through, and no threshold on
            // them says anything about what was recoverable.
            XCTAssertLessThan(Self.unchangedFraction(base, original, secretRect), survivalBudget,
                              "\(redaction): more original pixels survive in the stored base than the filter accounts for")
            XCTAssertLessThan(Self.unchangedFraction(flattened, original, secretRect), survivalBudget,
                              "\(redaction): more original pixels survive in the flattened PNG than the filter accounts for")

            controller.forceTeardownForTesting()
        }
    }

    func testARedactionDoesNotComeBackAsAnEditableMark() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(AnnotationItem(payload: .blur(secretRect),
                                   ink: AnnotationInk.presets[0], strokeWidth: 1))
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        let second = try annotate(path)
        XCTAssertEqual(second.items.count, 1, "only the arrow returns")
        XCTAssertFalse(try XCTUnwrap(second.items.first).payload.isRedaction)
    }

    /// With nothing left to edit, the sidecars go rather than lingering and
    /// redrawing marks that are already pixels.
    func testAnAllRedactionApplyLeavesNoSidecar() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(AnnotationItem(payload: .blur(secretRect),
                                   ink: AnnotationInk.presets[0], strokeWidth: 1))
        await controller.applyAnnotationsForTesting()

        XCTAssertFalse(AnnotationMarkStore.hasEditableMarks(for: path))
        XCTAssertNil(AnnotationMarkStore.restore(for: path))

        let second = try annotate(path)
        XCTAssertTrue(second.items.isEmpty, "a reopen starts clean on the flattened image")
    }

    /// Splitting after the LAST redaction rather than hoisting all redactions
    /// out: a mark drawn under a blur has to stay under it.
    func testAMarkBeneathARedactionIsBakedRatherThanRaisedAboveIt() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        // Arrow first, blur over the top of it, then a second arrow.
        session.add(arrow(CGPoint(x: 15, y: 15), CGPoint(x: 65, y: 35)))
        session.add(AnnotationItem(payload: .blur(secretRect),
                                   ink: AnnotationInk.presets[0], strokeWidth: 1))
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        let second = try annotate(path)
        XCTAssertEqual(second.items.count, 1,
                       "the buried arrow is permanent; only the one above the blur returns")
        guard case let .arrow(from, _, _) = try XCTUnwrap(second.items.first).payload else {
            return XCTFail("wrong payload")
        }
        XCTAssertEqual(from.x, 80, accuracy: 0.001, "the surviving mark is the later one")
    }

    /// Undoing back to the loaded state has to report clean.
    ///
    /// Dirty used to mean `!items.isEmpty || !undoStack.isEmpty`, which for a
    /// session opened from saved marks was true from the moment it opened and
    /// could never become false again: undoing an edit all the way back still
    /// demanded Apply or Discard for a change that no longer existed.
    func testUndoingBackToTheLoadedStateGoesCleanAgain() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        let second = try annotate(path)
        XCTAssertFalse(second.isDirty)

        let mark = try XCTUnwrap(second.items.first)
        second.selectedItemID = mark.id
        second.deleteSelected()
        XCTAssertTrue(second.isDirty, "deleting a restored mark is an edit")

        second.undo()

        XCTAssertEqual(second.items.count, 1)
        XCTAssertFalse(second.isDirty,
                       "back at the loaded state, so there is nothing to apply or discard")
    }

    /// A mark made while capturing has to be as editable later as one added
    /// afterwards.
    ///
    /// The capture commit rendered one flat composite and wrote only the PNG, so
    /// annotating during capture - the common way to do it - produced an image
    /// whose marks were pixels forever. Reopening Annotate on it offered nothing
    /// to select, which read as re-editing being broken rather than absent.
    /// Measured on device: zero sidecars existed after a session of capture-time
    /// annotating.
    func testACaptureTimeAnnotationIsEditableAfterwards() async throws {
        // Stands in for the capture commit: the same split, the same write.
        let path = try storedImage()
        let source = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
        let session = AnnotationSession(source: source)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))

        let (flattened, base, items) = try await session.withAppliedSplit {
            ($0.flattened, $0.base, $0.editableItems)
        }
        let data = try AnnotationExporter.pngData(from: flattened)
        try AnnotationExporter.replaceOwnedData(data, at: path)
        try AnnotationMarkStore.write(base: base, items: items,
                                      flattenedPNG: data, for: path)
        session.teardown()

        let restored = try XCTUnwrap(AnnotationMarkStore.restore(for: path),
                                     "a capture-time mark must come back as a mark")
        XCTAssertEqual(restored.items.count, 1)
    }

    // MARK: - Deletion

    /// Deleting the image has to take the base with it.
    ///
    /// For a vector-only Apply there is no redaction to flatten, so the stored
    /// base is a byte-for-byte copy of the original capture. Removing only the
    /// primary PNG left that copy on disk after the user permanently deleted the
    /// comment it belonged to.
    func testDeletingTheImageRemovesTheBaseCopyOfTheCapture() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        let baseURL = resolveImagePath(AnnotationMarkStore.basePath(for: path))
        let marksURL = resolveImagePath(AnnotationMarkStore.marksPath(for: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseURL.path))

        // With no redaction the base IS the capture, which is what makes an
        // orphan here a data-remanence bug rather than wasted disk.
        let originalBytes = try Data(contentsOf: resolveImagePath(path))
        XCTAssertNotEqual(try Data(contentsOf: baseURL), originalBytes,
                          "sanity: the PNG has the arrow, the base does not")

        try AnnotationMarkStore.deleteImageFamily(path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.path),
                       "the editing base outlived the image it belongs to")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marksURL.path))
    }

    /// Reconciliation for pairs stranded by an older build or a partial failure.
    func testTheSweepCollectsSidecarsWhoseImageIsGone() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()
        controller.forceTeardownForTesting()

        // Exactly what an older delete path left behind: primary gone, pair kept.
        try FileManager.default.removeItem(at: resolveImagePath(path))
        let baseURL = resolveImagePath(AnnotationMarkStore.basePath(for: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseURL.path))

        AnnotationMarkStore.removeOrphanedSidecars()

        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: resolveImagePath(AnnotationMarkStore.marksPath(for: path)).path))
    }

    /// The sweep must not eat sidecars that are still in use.
    func testTheSweepLeavesLiveSidecarsAlone() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()

        AnnotationMarkStore.removeOrphanedSidecars()

        XCTAssertNotNil(AnnotationMarkStore.restore(for: path),
                        "the sweep removed a pair whose image is still present")
    }

    // MARK: - Stale pairs

    /// A sidecar that does not belong to the image on disk must be refused.
    ///
    /// Apply commits the PNG before it writes the pair, so a crash in between
    /// used to leave an older base+marks that still parsed and still looked
    /// complete. Replaying it would redraw marks that are already pixels, or
    /// lift a redaction the newer image had applied. The marks carry a
    /// fingerprint of the PNG they were written against, so the mismatch is
    /// caught on read instead of depending on write ordering surviving a crash.
    func testMarksAreRefusedWhenTheImageMovedOnWithoutThem() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()
        XCTAssertNotNil(AnnotationMarkStore.restore(for: path), "baseline: the pair is good")

        // Stand in for the crash window: the PNG moves on, the pair does not.
        let replacement = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
        try AnnotationExporter.replaceOwnedData(
            try AnnotationExporter.pngData(from: replacement).dropLast(0) + Data([0x0a]),
            at: path)

        XCTAssertNil(AnnotationMarkStore.restore(for: path),
                     "a pair that predates the stored image must not be replayed")
        XCTAssertFalse(AnnotationMarkStore.hasEditableMarks(for: path))
    }

    // MARK: - Fallback

    func testAnImageWithNoSidecarAnnotatesFromTheFlattenedPng() throws {
        let path = try storedImage()
        XCTAssertNil(AnnotationMarkStore.restore(for: path))

        let session = try annotate(path)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertEqual(session.pixelSize, CGSize(width: 120, height: 80))
    }

    func testACorruptSidecarFallsBackInsteadOfFailingToOpen() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        let session = try annotate(path)
        session.add(arrow(CGPoint(x: 80, y: 60), CGPoint(x: 110, y: 75)))
        await controller.applyAnnotationsForTesting()
        XCTAssertTrue(AnnotationMarkStore.hasEditableMarks(for: path))

        try Data("{ not json".utf8).write(
            to: resolveImagePath(AnnotationMarkStore.marksPath(for: path)))

        XCTAssertNil(AnnotationMarkStore.restore(for: path))
        let second = try annotate(path)
        XCTAssertTrue(second.items.isEmpty, "the image still opens, just not re-editable")
    }

    // MARK: - Pixel helpers

    private static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The raw bytes of one region, for exact comparison between two images.
    private static func region(_ image: CGImage, _ rect: CGRect) -> [UInt8] {
        let bytes = rgbaBytes(image)
        var out: [UInt8] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * image.width + x) * 4
                out.append(contentsOf: bytes[i..<(i + 4)])
            }
        }
        return out
    }

    /// Horizontal transitions along the middle row: how much structure a region
    /// carries. Used only to prove the FIXTURE has detail worth destroying.
    private static func stripeEdges(_ image: CGImage, _ rect: CGRect) -> Int {
        let bytes = rgbaBytes(image)
        let y = Int(rect.midY)
        var edges = 0
        var previous: Int?
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let i = (y * image.width + x) * 4
            let luma = Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
            if let previous, abs(luma - previous) > 150 { edges += 1 }
            previous = luma
        }
        return edges
    }

    /// Fraction of pixels in the region that still hold their original value.
    ///
    /// Filter-agnostic, which is the point: it states what actually matters
    /// about a redaction - the stored pixels are not the ones that were there -
    /// without depending on how any particular filter transforms them.
    private static func unchangedFraction(_ image: CGImage,
                                          _ original: CGImage,
                                          _ rect: CGRect) -> Double {
        let a = region(image, rect), b = region(original, rect)
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var same = 0
        for i in stride(from: 0, to: a.count, by: 4) where
            a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2] { same += 1 }
        return Double(same) / Double(a.count / 4)
    }

    private static func greenPixelCount(_ image: CGImage) -> Int {
        let bytes = rgbaBytes(image)
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where
            bytes[i + 1] > 180 && bytes[i] < 90 && bytes[i + 2] < 90 { count += 1 }
        return count
    }
}
