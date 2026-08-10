import XCTest
import AppKit
@testable import RemarcFeature

/// Drives the preview panel's annotation flow through the real controller.
///
/// Synthetic mouse events could not be used here: a CGEvent left-click on the
/// comment card reliably resolves to the card's SwiftUI `.contextMenu` rather than
/// its `.onTapGesture`, so the panel never opens. Calling the controller is what
/// actually exercises show -> annotate -> apply -> revision.
@MainActor
final class ScreenshotPreviewAnnotationTests: XCTestCase {

    private var storage = TemporaryStorageRoot()

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
    }

    override func tearDown() async throws {
        ScreenshotPreviewController.shared.forceTeardownForTesting()
        storage.remove()
    }

    private func storedImage() throws -> String {
        let image = TestImages.solid(width: 60, height: 40, red: 1, green: 0, blue: 0)
        let path = try AnnotationExporter.writeNewImage(image)
        return path
    }

    func testShowOpensAndDismissTearsDown() throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared

        controller.show(imagePath: path, commentText: "hello")
        XCTAssertTrue(controller.isPanelVisibleForTesting)
        XCTAssertFalse(controller.isAnnotating, "annotation is off until toggled")

        controller.requestDismiss(intent: .closeButton)
        XCTAssertFalse(controller.isPanelVisibleForTesting)
    }

    func testAnnotateCreatesASessionAtTheImagesExactPixelSize() throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)

        controller.toggleAnnotationForTesting()
        XCTAssertTrue(controller.isAnnotating)
        // Measured from the decoded image, never assumed from points.
        XCTAssertEqual(controller.sessionForTesting?.pixelSize, CGSize(width: 60, height: 40))
    }

    /// The core of Apply: flatten into the app-owned PNG, bump the revision, and
    /// leave the panel in non-annotation mode with a clean session.
    func testApplyFlattensIntoTheStoredPngAndBumpsTheRevision() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)
        controller.toggleAnnotationForTesting()

        let session = try XCTUnwrap(controller.sessionForTesting)
        session.add(AnnotationItem(
            payload: .rect(CGRect(x: 5, y: 5, width: 50, height: 30)),
            ink: AnnotationInk(red: 0, green: 0, blue: 1), strokeWidth: 6))
        XCTAssertTrue(session.isDirty)

        let revisionBefore = StoredImageRevisionCenter.shared.revision(for: path)
        let bytesBefore = try Data(contentsOf: resolveImagePath(path))

        await controller.applyAnnotationsForTesting()

        let bytesAfter = try Data(contentsOf: resolveImagePath(path))
        XCTAssertNotEqual(bytesBefore, bytesAfter, "Apply must rewrite the stored PNG")
        XCTAssertEqual(StoredImageRevisionCenter.shared.revision(for: path), revisionBefore + 1,
                       "thumbnails only reload when the revision moves")

        let reloaded = try XCTUnwrap(AnnotationExporter.decode(relativePath: path))
        XCTAssertEqual(reloaded.width, 60, "the exported file stays the source pixel size")
        XCTAssertEqual(reloaded.height, 40)
        // On the stroke, near the top edge of the rect.
        XCTAssertGreaterThan(TestImages.pixel(reloaded, x: 30, y: 6)[2], 100)

        XCTAssertFalse(controller.isAnnotating,
                       "Apply leaves the panel in non-annotation mode")
    }

    /// A drag inside the canvas must draw, not slide the panel across the screen.
    ///
    /// This panel sets `isMovableByWindowBackground`, and AppKit reads the hit
    /// view's `mouseDownCanMoveWindow` BEFORE it dispatches `mouseDown(with:)`.
    /// NSView's default returns true for a non-opaque view, so every mark drawn
    /// on a saved comment's image moved the window instead. Asserted against the
    /// assembled panel rather than a synthetic canvas, because the defect was in
    /// the hosting, not in the canvas in isolation.
    func testDraggingTheCanvasDoesNotMoveThePanel() throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)
        controller.toggleAnnotationForTesting()

        // SwiftUI materialises the representable's NSView on a runloop turn.
        let panel = try XCTUnwrap(controller.panelForTesting)
        panel.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertTrue(panel.isMovableByWindowBackground,
                      "if this ever goes false the hazard is gone and so is the point of this test")
        let canvas = try XCTUnwrap(controller.canvasForTesting,
                                   "the canvas must be reachable inside the assembled panel")
        XCTAssertFalse(canvas.mouseDownCanMoveWindow,
                       "a drag on the canvas would move the window instead of drawing")
    }

    /// A replacement `show()` waits for the user's decision instead of making it.
    ///
    /// This asserts the FIRST session survives, which is what the name promises.
    /// It previously only checked that the second image had become current -
    /// true both when the replacement waits and when it bulldozes the work, so
    /// it passed against the very bug it was named for. `show()` queued the
    /// request but routed the dismissal through `.replacement`, and that intent
    /// was explicitly exempt from the dirty veto, so the teardown ran anyway.
    func testASecondShowDoesNotDestroyADirtySessionSilently() throws {
        let first = try storedImage()
        let second = try storedImage()
        let controller = ScreenshotPreviewController.shared

        controller.show(imagePath: first, commentText: nil)
        controller.toggleAnnotationForTesting()
        let session = try XCTUnwrap(controller.sessionForTesting)
        session.add(AnnotationItem(payload: .rect(CGRect(x: 2, y: 2, width: 20, height: 10)),
                                   ink: AnnotationInk.presets[0], strokeWidth: 3))
        XCTAssertTrue(session.isDirty)

        controller.show(imagePath: second, commentText: nil)

        XCTAssertTrue(controller.sessionForTesting === session,
                      "the dirty session must survive an unresolved replacement")
        XCTAssertEqual(controller.currentImagePathForTesting, first,
                       "the panel stays on the image with unresolved work")

        // Discarding is a decision, and it releases the held request.
        controller.discardAnnotationsForTesting()

        XCTAssertNil(controller.sessionForTesting)
        XCTAssertEqual(controller.currentImagePathForTesting, second,
                       "the queued show opens once the work is resolved")
    }

    /// Typing a label does not make a session dirty, so the dirty gate alone
    /// never saw it and `show()` tore the panel down mid-word.
    func testAReplacementDoesNotDiscardALabelBeingTyped() throws {
        let first = try storedImage()
        let second = try storedImage()
        let controller = ScreenshotPreviewController.shared

        controller.show(imagePath: first, commentText: nil)
        controller.toggleAnnotationForTesting()
        let session = try XCTUnwrap(controller.sessionForTesting)
        session.beginText(at: CGPoint(x: 10, y: 10), pointSize: 12)
        session.updatePendingText("hello")
        XCTAssertFalse(session.isDirty, "a pending label is not yet an edit")

        controller.show(imagePath: second, commentText: nil)

        XCTAssertTrue(controller.sessionForTesting === session,
                      "the label was committed, which made the session dirty and held the show")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.items.count, 1, "the typed label became a mark rather than vanishing")
    }

    /// Apply suspends across two renders. Every control that resolves the
    /// session has to be inert for that window, or a Discard lands on top of a
    /// write that is still going to complete.
    func testResolutionIsRefusedWhileAnApplyIsInFlight() async throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)
        controller.toggleAnnotationForTesting()

        let session = try XCTUnwrap(controller.sessionForTesting)
        session.add(AnnotationItem(payload: .rect(CGRect(x: 2, y: 2, width: 20, height: 10)),
                                   ink: AnnotationInk.presets[0], strokeWidth: 3))

        controller.beginApplyForTesting()
        XCTAssertTrue(controller.isApplyingForTesting)

        controller.discardAnnotationsForTesting()
        XCTAssertTrue(controller.sessionForTesting === session,
                      "Discard must not clear the session out from under a commit")

        controller.requestDismiss(intent: .closeButton)
        XCTAssertTrue(controller.isPanelVisibleForTesting,
                      "the panel must not tear down while a write is in flight")

        await controller.finishApplyForTesting()
        XCTAssertNil(controller.sessionForTesting)
    }

    func testDismissIsRefusedWhileAnInlineLabelIsBeingTyped() throws {
        let path = try storedImage()
        let controller = ScreenshotPreviewController.shared
        controller.show(imagePath: path, commentText: nil)
        controller.toggleAnnotationForTesting()

        let session = try XCTUnwrap(controller.sessionForTesting)
        session.beginText(at: CGPoint(x: 10, y: 10), pointSize: 12)
        XCTAssertTrue(session.pendingTextIsActive)

        controller.requestDismiss(intent: .escape)

        XCTAssertTrue(controller.isPanelVisibleForTesting,
                      "one layer per invocation: the label resolves, the panel stays")
        XCTAssertFalse(session.pendingTextIsActive)
    }
}
