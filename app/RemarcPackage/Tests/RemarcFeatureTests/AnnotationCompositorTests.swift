import XCTest
import CoreGraphics
@testable import RemarcFeature

final class AnnotationCompositorTests: XCTestCase {

    private let size = CGSize(width: 120, height: 80)
    private lazy var base = TestImages.solid(width: 120, height: 80, red: 0, green: 0, blue: 1)

    private func snapshot(_ generation: Int, items: [AnnotationItem] = []) -> AnnotationCompositor.Snapshot {
        AnnotationCompositor.Snapshot(generation: generation, base: base,
                                      items: items, pixelSize: size)
    }

    func testSubmitPublishesTheGeneration() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(7))
        let published = await compositor.publishedGeneration
        XCTAssertEqual(published, 7)
    }

    func testCompositeIsExactlyThePixelSize() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(1))
        let image = try await compositor.composite(atLeast: 1)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    /// The display raster follows the screen; the EXPORT raster is always exactly
    /// the source pixel dimensions.
    ///
    /// The two were once the same object, which was the original parity claim.
    /// That made a magnified stage draw strokes rasterized at source resolution and
    /// then blown up, which is visibly jagged. The claim is now narrower and
    /// stated as such: both come from the same renderer and the same item list, and
    /// the file is always exactly `pixelSize`.
    func testTheExportRasterIsSourceSizedWhateverTheDisplayScale() async throws {
        let compositor = AnnotationCompositor()
        let mark = AnnotationItem(payload: .rect(CGRect(x: 10, y: 10, width: 80, height: 40)),
                                  ink: AnnotationInk.presets[0], strokeWidth: 6)

        await compositor.submit(AnnotationCompositor.Snapshot(
            generation: 1, base: base, items: [mark], pixelSize: size, displayScale: 4))
        let display = try await compositor.composite(atLeast: 1)
        XCTAssertEqual(display.width, 480, "the display raster follows the screen")
        XCTAssertEqual(display.height, 320)

        let export = try await compositor.renderForOutput(
            base: base, items: [mark], pixelSize: size)
        XCTAssertEqual(export.width, 120, "the file is always the source pixel size")
        XCTAssertEqual(export.height, 80)
    }

    func testADisplayScaleOfOneMatchesTheExportDimensions() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(1))
        let display = try await compositor.composite(atLeast: 1)
        let export = try await compositor.renderForOutput(
            base: base, items: [], pixelSize: size)
        XCTAssertEqual(display.width, export.width)
        XCTAssertEqual(display.height, export.height)
    }

    func testAnAlreadyPublishedGenerationIsReusedNotReRendered() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(3))
        let a = try await compositor.composite(atLeast: 3)
        let b = try await compositor.composite(atLeast: 3)
        XCTAssertTrue(a === b, "a published generation must not re-render per reader")
    }

    func testAnAlreadyPublishedGenerationReturnsWithoutSuspending() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(5))
        // Asking for something older must not hang waiting for a render that will
        // never be submitted.
        let image = try await compositor.composite(atLeast: 2)
        XCTAssertEqual(image.width, 120)
    }

    /// Submitting N supersedes any queued generation below N that has not started.
    /// Intermediate generations are dropped rather than rendered and discarded.
    func testAWaiterIsSatisfiedByANewerGeneration() async throws {
        let compositor = AnnotationCompositor()

        let waiter = Task { try await compositor.composite(atLeast: 4) }
        // Give the waiter a turn to register before anything is published.
        await Task.yield()

        await compositor.submit(snapshot(9))
        let image = try await waiter.value
        XCTAssertEqual(image.width, 120)

        let published = await compositor.publishedGeneration
        XCTAssertEqual(published, 9)
    }

    func testResetResumesEveryWaiterRatherThanStrandingThem() async throws {
        let compositor = AnnotationCompositor()
        let waiter = Task { try await compositor.composite(atLeast: 50) }
        await Task.yield()

        await compositor.reset()

        do {
            _ = try await waiter.value
            XCTFail("a waiter for a generation that will never arrive must not hang")
        } catch {
            XCTAssertEqual(error as? AnnotationCompositor.CompositorError, .cancelled)
        }
    }

    func testAStaleRenderNeverOverwritesANewerComposite() async throws {
        let compositor = AnnotationCompositor()
        await compositor.submit(snapshot(10))
        await compositor.submit(snapshot(4))   // older generation arriving late
        let published = await compositor.publishedGeneration
        XCTAssertEqual(published, 10, "an older result must be ignored")
    }

    func testItemsActuallyReachTheComposite() async throws {
        let compositor = AnnotationCompositor()
        let mark = AnnotationItem(
            payload: .rect(CGRect(x: 10, y: 10, width: 100, height: 60)),
            ink: AnnotationInk(red: 1, green: 0, blue: 0), strokeWidth: 8)
        await compositor.submit(snapshot(1, items: [mark]))
        let image = try await compositor.composite(atLeast: 1)
        let onTheStroke = TestImages.pixel(image, x: 60, y: 11)
        XCTAssertGreaterThan(onTheStroke[0], 120)
    }

    func testPatchRendersWithoutTouchingTheActorState() async throws {
        let compositor = AnnotationCompositor()
        let cache = await compositor.filterCache()
        let patch = AnnotationCompositor.patch(
            base: base, items: [], pixelSize: size,
            region: CGRect(x: 20, y: 10, width: 40, height: 30), filters: cache)
        XCTAssertEqual(patch?.width, 40)
        XCTAssertEqual(patch?.height, 30)
        let published = await compositor.publishedGeneration
        XCTAssertEqual(published, -1, "the transient path must not publish a generation")
    }

    func testAFullFiveKRenderMeetsTheStatedBudget() async throws {
        // The spec records a target of one full committed render under 250ms at 5K.
        let big = TestImages.solid(width: 5120, height: 2880, red: 0.2, green: 0.4, blue: 0.6)
        let compositor = AnnotationCompositor()
        let items = (0..<12).map { i in
            AnnotationItem(payload: .rect(CGRect(x: 100 * i, y: 80 * i, width: 400, height: 300)),
                           ink: AnnotationInk.presets[i % AnnotationInk.presets.count],
                           strokeWidth: 8)
        }
        let start = ProcessInfo.processInfo.systemUptime
        await compositor.submit(AnnotationCompositor.Snapshot(
            generation: 1, base: big, items: items,
            pixelSize: CGSize(width: 5120, height: 2880)))
        _ = try await compositor.composite(atLeast: 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 0.25, "5K committed render took \(elapsed)s")
    }
}
