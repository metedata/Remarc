# Screenshot Annotation - Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the two AppKit assumptions the whole design rests on, then build the pure, dependency-free geometry core of the annotation engine with full unit coverage.

**Architecture:** Two throwaway spike binaries answer empirical questions that can invalidate the design before any production code exists. Then four pure value-type modules land under `Annotation/`, each with no AppKit view dependencies, each unit-tested in isolation. Nothing in this phase touches `PersistenceManager`, `ScreenCaptureService`, or any view.

**Tech Stack:** Swift 6, AppKit, Core Graphics, XCTest. No new package dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-06-screenshot-annotation-design.md` (revision 6, commit `444af85`).

## Global Constraints

- Deployment target macOS 14 (`app/RemarcPackage/Package.swift:7`). No API newer than that.
- **Spikes must be compiled with `-target arm64-apple-macos14.0`.** `CGWindowListCreateImage` is *unavailable*, not merely deprecated, at deployment targets from macOS 15 onward. Measured on this machine: bare `swiftc` (which targets the host) fails with `'CGWindowListCreateImage' is unavailable in macOS: Please use ScreenCaptureKit instead`, while the same file with `-target arm64-apple-macos14.0` compiles with only a deprecation warning. The app itself compiles for the same reason. A spike built without the flag tests nothing.
- All code changes happen in the worktree `.worktrees/screenshot-annotation` on branch `feat/screenshot-annotation`. Never on `main`.
- Copy style: never use em dashes. Use hyphens.
- Colors come from `remarc*` tokens in `Views/Colors.swift`. Never hardcode hex. (Not exercised in this phase; applies from Phase 3.)
- All committed annotation geometry is in **source-image pixel coordinates, top-left origin**.
- Mark geometry (stroke width, arrowheads, text size, counter radius) never scales with zoom. Editor chrome always does.
- Filter geometry and cache keys never include a zoom factor.
- Build: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`
- Test: `cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/<ClassName> -quiet`
- After any successful **app** build, relaunch: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

## Phase scope

In: the two blocking gate spikes, plus `AnnotationStageGeometry`, `AnnotationViewport`, `AnnotationPanelGeometry`, `AnnotationItem`.

Out, each needing its own plan:
- **Phase 2 - durable persistence.** BLOCKED: the data-layer spec calls for dirty-entity rebasing but `AppStateMerge` three-way merge shipped instead, and the `unknownFields` passthrough is unshipped. Resolve before writing `createCommentDurably`. See the spec's Coordination section.
- **Phase 3 - canvas, toolbar, compositor.**
- **Phase 4 - preview integration.**
- **Phase 5 - capture integration and magnification.**

---

### Task 1: Spike A - freeze-grab fidelity

The freeze grab runs `.optionOnScreenBelowWindow` while the dimming overlay is at **full alpha**, which is the first time that path runs outside teardown. If it returns 50%-dimmed pixels, WYSIWYG and every exported PNG break silently and the design is moot. Unverified on device.

**Files:**
- Create: `.worktrees/screenshot-annotation/spikes/freeze-grab/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a PASS/FAIL verdict recorded in the plan. No production code.

- [ ] **Step 1: Write the spike**

Create `spikes/freeze-grab/main.swift`:

```swift
import AppKit

// Does CGWindowListCreateImage(.optionOnScreenBelowWindow) see through a
// full-alpha dimming overlay? Puts a known pure-red window on screen, covers it
// with a 50%-black overlay at .screenSaver, grabs below the overlay, and samples
// the centre pixel. Pure red means the grab ignored the overlay (design holds).
// Dark red means it did not (design is moot).

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard CGPreflightScreenCaptureAccess() else {
    print("FAIL: no screen recording permission for this process.")
    print("Grant Terminal (or the host app) Screen Recording in System Settings, then rerun.")
    CGRequestScreenCaptureAccess()
    exit(2)
}

let target = NSRect(x: 300, y: 300, width: 400, height: 300)

// 1. A known pure-red window underneath.
let red = NSWindow(contentRect: target, styleMask: .borderless, backing: .buffered, defer: false)
red.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
red.isOpaque = true
red.level = .normal
red.orderFrontRegardless()

// 2. A dimming overlay above it, exactly as RegionSelectionView draws it.
final class Dim: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
let overlayFrame = target.insetBy(dx: -100, dy: -100)
let overlay = NSPanel(contentRect: overlayFrame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
overlay.backgroundColor = .clear
overlay.isOpaque = false
overlay.hasShadow = false
overlay.level = .screenSaver
overlay.contentView = Dim(frame: NSRect(origin: .zero, size: overlayFrame.size))
overlay.orderFrontRegardless()

RunLoop.current.run(until: Date().addingTimeInterval(1.0))

// 3. Grab below the overlay, in Quartz coordinates (top-left origin).
let primaryHeight = NSScreen.screens.first?.frame.height ?? target.height
let quartz = CGRect(x: target.origin.x,
                    y: primaryHeight - target.origin.y - target.height,
                    width: target.width, height: target.height)
let wid = CGWindowID(overlay.windowNumber)

guard let image = CGWindowListCreateImage(quartz, .optionOnScreenBelowWindow, wid, [.bestResolution]) else {
    print("FAIL: CGWindowListCreateImage returned nil")
    exit(1)
}

// 4. Sample the centre pixel.
let w = image.width, h = image.height
guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }
var px: [UInt8] = [0, 0, 0, 0]
guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(image, in: CGRect(x: -CGFloat(w / 2), y: -CGFloat(h / 2),
                           width: CGFloat(w), height: CGFloat(h)))

print("grabbed \(w)x\(h), centre pixel RGBA = \(px[0]), \(px[1]), \(px[2]), \(px[3])")
if px[0] > 240 && px[1] < 40 && px[2] < 40 {
    print("PASS: grab ignored the full-alpha overlay. Freeze-on-toggle is viable.")
    exit(0)
} else if px[0] > 100 && px[0] < 200 {
    print("FAIL: grab captured DIMMED pixels. Freeze-on-toggle as specced is not viable.")
    exit(1)
} else {
    print("INCONCLUSIVE: unexpected colour. Check window ordering and rerun.")
    exit(3)
}
```

- [ ] **Step 2: Build and run it**

```bash
cd spikes/freeze-grab && swiftc -O -target arm64-apple-macos14.0 main.swift -o freeze-grab && ./freeze-grab
```

Expected: one of three lines. `PASS` means proceed. `FAIL: grab captured DIMMED pixels` means **stop and report** - the design's freeze step needs rework (likely: drop overlay alpha to 0 for one frame before grabbing, then restore). `FAIL: no screen recording permission` means grant Terminal Screen Recording and rerun.

- [ ] **Step 3: Record the verdict in the spec**

Edit `docs/superpowers/specs/2026-08-06-screenshot-annotation-design.md`, in "Blocking gates before feature code", replacing gate 1's "**Unverified on device.**" with the measured result and the date.

- [ ] **Step 4: Commit**

```bash
git add spikes/freeze-grab/main.swift docs/superpowers/specs/2026-08-06-screenshot-annotation-design.md
git commit -m "spike: verify freeze grab sees through a full-alpha overlay"
```

---

### Task 2: Spike B - subview over the cleared cutout

`RegionSelectionView` has never had a subview, and its transparent cutout depends on `.clear` compositing against the panel backing store (`ScreenCaptureService.swift:67-69`). The design adds an opaque child over exactly that region. No example of `.clear` compositing coexisting with a subview exists anywhere in the codebase.

**Files:**
- Create: `.worktrees/screenshot-annotation/spikes/subview-cutout/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a PASS/FAIL verdict. No production code.

- [ ] **Step 1: Write the spike**

Create `spikes/subview-cutout/main.swift`:

```swift
import AppKit

// Three questions, all unverified in this codebase:
//  (a) does a plain non-layer-backed child draw OPAQUE pixels over a region the
//      superview cleared with .clear compositing?
//  (b) does the parent's cutout still produce transparency when no child is present?
//  (c) does regionView.layer stay nil after adding the child?

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let frame = NSRect(x: 400, y: 400, width: 400, height: 300)
let cutout = NSRect(x: 100, y: 75, width: 200, height: 150)

final class Parent: NSView {
    var drawChild = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: cutout, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}

final class Child: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()   // pure green
        NSBezierPath(rect: bounds).fill()
    }
}

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.level = .screenSaver
let parent = Parent(frame: NSRect(origin: .zero, size: frame.size))
panel.contentView = parent
panel.orderFrontRegardless()
RunLoop.current.run(until: Date().addingTimeInterval(0.6))

func samplePixel(at screenPoint: CGPoint) -> [UInt8] {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let q = CGRect(x: screenPoint.x, y: primaryHeight - screenPoint.y, width: 1, height: 1)
    guard let img = CGWindowListCreateImage(q, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [0, 0, 0, 0] }
    var px: [UInt8] = [0, 0, 0, 0]
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return px }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height)))
    return px
}

let centre = CGPoint(x: frame.minX + cutout.midX, y: frame.minY + cutout.midY)
let before = samplePixel(at: centre)
print("(b) cutout with NO child, centre pixel = \(before)  [expect desktop colour, not 50% black]")

let child = Child(frame: cutout)
parent.addSubview(child)
parent.needsDisplay = true
RunLoop.current.run(until: Date().addingTimeInterval(0.6))

let after = samplePixel(at: centre)
print("(a) cutout WITH child, centre pixel = \(after)  [expect pure green 0,255,0]")
print("(c) parent.layer == nil -> \(parent.layer == nil)   child.layer == nil -> \(child.layer == nil)")

let opaqueGreen = after[1] > 240 && after[0] < 40 && after[2] < 40
let stillUnlayered = parent.layer == nil
if opaqueGreen && stillUnlayered {
    print("PASS: opaque child composites over the cleared region, ancestors stay unlayered.")
    exit(0)
} else {
    print("FAIL: opaqueGreen=\(opaqueGreen) stillUnlayered=\(stillUnlayered)")
    print("If the child is not opaque, the canvas must own the whole region and the parent must stop clearing.")
    exit(1)
}
```

- [ ] **Step 2: Build and run it**

```bash
cd spikes/subview-cutout && swiftc -O -target arm64-apple-macos14.0 main.swift -o subview-cutout && ./subview-cutout
```

Expected: `PASS`. A failure on `(a)` means the canvas must own the entire selection region and the parent must stop clearing while annotating - a contained change to the parent-view gating table, not a redesign. A failure on `(c)` means the cutout must be reimplemented as a `CAShapeLayer` even-odd mask.

- [ ] **Step 3: Record the verdict in the spec**

Edit the spec's gate 2, replacing "**Unverified.**" with the measured result and date.

- [ ] **Step 4: Commit**

```bash
git add spikes/subview-cutout/main.swift docs/superpowers/specs/2026-08-06-screenshot-annotation-design.md
git commit -m "spike: verify an opaque subview composites over the cleared cutout"
```

---

### Task 3: AnnotationStageGeometry

Pure magnification math. No AppKit views, no state. This is the module the round-3 and round-5 reviews attacked hardest: it must return `effectiveZoom` alongside the rect, and `zMax` must be alignment-aware.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationStageGeometry.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationStageGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum StageDockEdge { case leading, trailing, top, bottom }`
  - `AnnotationStageGeometry.allowance(visible:edge:panelReserve:toolbarReserve:edgePad:) -> CGRect?` (nil means magnification disabled)
  - `AnnotationStageGeometry.fitZoom(selection:allowance:) -> CGFloat`
  - `AnnotationStageGeometry.resolvedMaxZoom(selection:allowance:backingScale:hardCap:) -> Int`
  - `AnnotationStageGeometry.autoZoom(selection:maxZoom:comfortEdge:) -> Int`
  - `AnnotationStageGeometry.displayRect(selection:requestedZoom:allowance:backingScale:) -> (effectiveZoom: Int, rect: CGRect)`

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationStageGeometryTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

/// Capture-time magnification geometry. All rects are RegionSelectionView-local
/// points: unflipped, bottom-left origin, 0-based.
final class AnnotationStageGeometryTests: XCTestCase {

    private let allowanceRect = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func selection(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: 200, y: 200, width: w, height: h)
    }

    // MARK: - Allowance

    func testAllowanceReservesPanelOnTheDockedSide() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let a = AnnotationStageGeometry.allowance(
            visible: visible, edge: .leading, panelReserve: 352, toolbarReserve: 260, edgePad: 8
        )
        XCTAssertEqual(a?.minX, 260)
        XCTAssertEqual(a?.maxX, 1512 - 352)
        XCTAssertEqual(a?.minY, 8)
        XCTAssertEqual(a?.maxY, 892)
    }

    func testAllowanceMirrorsForTrailingDock() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let a = AnnotationStageGeometry.allowance(
            visible: visible, edge: .trailing, panelReserve: 352, toolbarReserve: 260, edgePad: 8
        )
        XCTAssertEqual(a?.minX, 352)
        XCTAssertEqual(a?.maxX, 1512 - 260)
    }

    func testVerticalDocksDisableMagnification() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        XCTAssertNil(AnnotationStageGeometry.allowance(
            visible: visible, edge: .top, panelReserve: 352, toolbarReserve: 260, edgePad: 8))
        XCTAssertNil(AnnotationStageGeometry.allowance(
            visible: visible, edge: .bottom, panelReserve: 352, toolbarReserve: 260, edgePad: 8))
    }

    // MARK: - Zoom ladder

    func testAutoZoomMatchesTheSpecTable() {
        func auto(_ w: CGFloat, _ h: CGFloat) -> Int {
            let s = selection(w, h)
            let maxZ = AnnotationStageGeometry.resolvedMaxZoom(
                selection: s, allowance: allowanceRect, backingScale: 2, hardCap: 8)
            return AnnotationStageGeometry.autoZoom(selection: s.size, maxZoom: maxZ, comfortEdge: 320)
        }
        XCTAssertEqual(auto(200, 80), 4, "the motivating case")
        XCTAssertEqual(auto(40, 40), 8, "favicon, capped by hardCap")
        XCTAssertEqual(auto(400, 300), 2, "mild help")
        XCTAssertEqual(auto(900, 600), 1, "inert")
        XCTAssertEqual(auto(1200, 30), 1, "long thin strip, fit floors to 1")
    }

    func testZoomOfOneReturnsTheSelectionExactly() {
        let s = selection(200, 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 1, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.effectiveZoom, 1)
        XCTAssertEqual(r.rect, s, "z == 1 must be byte-identical to today's geometry")
    }

    func testEffectiveZoomAlwaysMatchesTheRectItReturns() {
        let s = selection(200, 80)
        for z in 1...8 {
            let r = AnnotationStageGeometry.displayRect(
                selection: s, requestedZoom: z, allowance: allowanceRect, backingScale: 2)
            XCTAssertEqual(r.rect.width / s.width, CGFloat(r.effectiveZoom), accuracy: 0.0001,
                           "requested \(z) reported \(r.effectiveZoom) but the rect disagrees")
        }
    }

    /// Centred in the allowance, so growth is never clamped and the assertions are
    /// about alignment rather than about hitting an edge.
    private func centredSelection(_ w: CGFloat, _ h: CGFloat, offset: CGFloat = 0) -> CGRect {
        CGRect(x: allowanceRect.midX - w / 2 + offset,
               y: allowanceRect.midY - h / 2 + offset,
               width: w, height: h)
    }

    func testAlignmentMovesOriginOnlyNeverSize() {
        let s = centredSelection(200, 80, offset: 0.3)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.width, 800, accuracy: 0.0001)
        XCTAssertEqual(r.rect.height, 320, accuracy: 0.0001)
        XCTAssertEqual((r.rect.minX * 2).rounded(), r.rect.minX * 2, accuracy: 0.0001,
                       "origin must sit on the backing grid")
        XCTAssertEqual((r.rect.minY * 2).rounded(), r.rect.minY * 2, accuracy: 0.0001)
    }

    func testEmptyAlignedIntervalReducesZoom() {
        // An allowance barely wider than 2x forces a reduction from 3x.
        let s = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tight = CGRect(x: 0, y: 0, width: 250, height: 250)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 3, allowance: tight, backingScale: 2)
        XCTAssertLessThan(r.effectiveZoom, 3)
        XCTAssertEqual(r.rect.width / s.width, CGFloat(r.effectiveZoom), accuracy: 0.0001)
    }

    func testResolvedMaxZoomIsAchievable() {
        // Whatever zMax says, requesting it must actually deliver it. Otherwise the
        // stepper sits enabled and inert.
        let s = selection(200, 80)
        let maxZ = AnnotationStageGeometry.resolvedMaxZoom(
            selection: s, allowance: allowanceRect, backingScale: 2, hardCap: 8)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: maxZ, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.effectiveZoom, maxZ)
    }

    func testDisplayRectAlwaysFitsInsideTheAllowanceAboveOneX() {
        let s = selection(200, 80)
        for z in 2...8 {
            let r = AnnotationStageGeometry.displayRect(
                selection: s, requestedZoom: z, allowance: allowanceRect, backingScale: 2)
            guard r.effectiveZoom > 1 else { continue }
            XCTAssertTrue(allowanceRect.insetBy(dx: -0.5, dy: -0.5).contains(r.rect),
                          "z=\(z) escaped the allowance: \(r.rect)")
        }
    }

    func testCentredGrowthKeepsTheMidpointWithinOneDevicePixel() {
        // Must be centred in the allowance: a selection near an edge is legitimately
        // translated by the clamp, and the invariant is explicitly scoped to the
        // unclamped case.
        let s = centredSelection(200, 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.midX, s.midX, accuracy: 0.5)
        XCTAssertEqual(r.rect.midY, s.midY, accuracy: 0.5)
    }

    func testSelectionNearAnEdgeIsTranslatedNotResized() {
        let s = CGRect(x: 4, y: 4, width: 200, height: 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.width, 800, accuracy: 0.0001, "the clamp translates, never resizes")
        XCTAssertGreaterThanOrEqual(r.rect.minX, allowanceRect.minX - 0.5)
        XCTAssertGreaterThanOrEqual(r.rect.minY, allowanceRect.minY - 0.5)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationStageGeometryTests -quiet 2>&1 | tail -15
```

Expected: FAIL, "cannot find 'AnnotationStageGeometry' in scope".

- [ ] **Step 3: Write the implementation**

Create `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationStageGeometry.swift`:

```swift
import Foundation
import CoreGraphics

/// Which side of the selection the comment panel is docked to. Mirrors the edge
/// `screenshotPanelOrigin` picks: `.leading` means the panel sits to the RIGHT of
/// the selection, `.trailing` to the left.
public enum StageDockEdge: Sendable {
    case leading, trailing, top, bottom
}

/// Pure geometry for capture-time magnification.
///
/// Every rect here is `RegionSelectionView`-local: unflipped, bottom-left origin,
/// 0-based, because `panel.contentView = regionView` discards the screen origin.
/// Converting to screen-global happens exactly once, outside this type.
public enum AnnotationStageGeometry {

    public static let hardCapDefault = 8
    public static let comfortEdgeDefault: CGFloat = 320
    public static let edgePadDefault: CGFloat = 8

    // MARK: - Allowance box

    /// The region the magnified image may occupy, with the comment panel's
    /// footprint reserved on its docked side and the toolbar's on the opposite one.
    ///
    /// Returns nil for vertical docks, which only occur when neither side has room
    /// for the panel - meaning a selection roughly 800pt or wider, which is not a
    /// small area and does not need magnifying.
    public static func allowance(
        visible: CGRect,
        edge: StageDockEdge,
        panelReserve: CGFloat,
        toolbarReserve: CGFloat,
        edgePad: CGFloat = edgePadDefault
    ) -> CGRect? {
        let minY = visible.minY + edgePad
        let maxY = visible.maxY - edgePad
        guard maxY > minY else { return nil }

        switch edge {
        case .leading:
            let minX = visible.minX + toolbarReserve
            let maxX = visible.maxX - panelReserve
            guard maxX > minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .trailing:
            let minX = visible.minX + panelReserve
            let maxX = visible.maxX - toolbarReserve
            guard maxX > minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .top, .bottom:
            return nil
        }
    }

    // MARK: - Zoom ladder

    /// Largest uniform scale that fits, ignoring backing alignment.
    public static func fitZoom(selection: CGSize, allowance: CGRect) -> CGFloat {
        guard selection.width > 0, selection.height > 0 else { return 1 }
        return min(allowance.width / selection.width, allowance.height / selection.height)
    }

    /// Largest integer zoom that is actually ACHIEVABLE once the origin is
    /// backing-aligned. `floor(fitZoom)` can overstate it, which would leave the
    /// zoom stepper permanently enabled and permanently inert.
    public static func resolvedMaxZoom(
        selection: CGRect,
        allowance: CGRect,
        backingScale: CGFloat,
        hardCap: Int = hardCapDefault
    ) -> Int {
        let fit = fitZoom(selection: selection.size, allowance: allowance)
        let ceiling = max(1, min(Int(fit.rounded(.down)), hardCap))
        var z = ceiling
        while z > 1 {
            if displayRect(selection: selection, requestedZoom: z,
                           allowance: allowance, backingScale: backingScale).effectiveZoom == z {
                return z
            }
            z -= 1
        }
        return 1
    }

    /// Zoom applied automatically on entering annotation, so a small region is
    /// immediately big enough to draw on.
    public static func autoZoom(
        selection: CGSize,
        maxZoom: Int,
        comfortEdge: CGFloat = comfortEdgeDefault
    ) -> Int {
        let shortest = min(selection.width, selection.height)
        guard shortest > 0 else { return 1 }
        let needed = Int((comfortEdge / shortest).rounded(.up))
        return min(max(needed, 1), maxZoom)
    }

    // MARK: - Display rect

    /// The on-screen rect for a requested zoom, plus the zoom actually achieved.
    ///
    /// Callers must publish `effectiveZoom`, never the value they requested: when
    /// the backing-aligned origin interval is empty this reduces the zoom, and a
    /// stepper or label reading the request would lie.
    public static func displayRect(
        selection: CGRect,
        requestedZoom: Int,
        allowance: CGRect,
        backingScale: CGFloat
    ) -> (effectiveZoom: Int, rect: CGRect) {
        guard requestedZoom > 1 else { return (1, selection) }

        let scale = CGFloat(requestedZoom)
        let size = CGSize(width: selection.width * scale, height: selection.height * scale)
        let rawX = selection.midX - size.width / 2
        let rawY = selection.midY - size.height / 2

        // Align the permitted interval INWARD first. Clamping and then rounding can
        // push the rect back outside the allowance by up to one device pixel.
        let loX = alignUp(allowance.minX, backingScale)
        let hiX = alignDown(allowance.maxX - size.width, backingScale)
        let loY = alignUp(allowance.minY, backingScale)
        let hiY = alignDown(allowance.maxY - size.height, backingScale)

        guard loX <= hiX, loY <= hiY else {
            return displayRect(selection: selection, requestedZoom: requestedZoom - 1,
                               allowance: allowance, backingScale: backingScale)
        }

        let x = min(max(alignNearest(rawX, backingScale), loX), hiX)
        let y = min(max(alignNearest(rawY, backingScale), loY), hiY)
        return (requestedZoom, CGRect(x: x, y: y, width: size.width, height: size.height))
    }

    // MARK: - Backing alignment

    private static func alignUp(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(.up) / scale
    }

    private static func alignDown(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(.down) / scale
    }

    private static func alignNearest(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationStageGeometryTests -quiet 2>&1 | tail -15
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationStageGeometry.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationStageGeometryTests.swift
git commit -m "feat(annotation): pure magnification stage geometry"
```

---

### Task 4: AnnotationViewport

Transforms between source-image pixels and a surface's canvas bounds. Independent X and Y scale, because the captured image is never assumed to have exactly the selection's aspect ratio.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationViewport.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationViewportTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct AnnotationViewport: Equatable` with `init(pixelSize: CGSize, canvasBounds: CGRect)`
  - `.pixel(fromCanvas: CGPoint) -> CGPoint` (clipped to the image)
  - `.canvas(fromPixel: CGPoint) -> CGPoint`
  - `.scaleX: CGFloat`, `.scaleY: CGFloat`

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationViewportTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

/// Probe points are deliberately ASYMMETRIC. A symmetric fixture passes even with
/// the vertical flip inverted, and a wrong flip is a silently mirrored export.
final class AnnotationViewportTests: XCTestCase {

    func testIdentityWhenCanvasBoundsEqualPixelSize() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 400, height: 160))
        XCTAssertEqual(v.scaleX, 1, accuracy: 0.0001)
        XCTAssertEqual(v.scaleY, 1, accuracy: 0.0001)
        let p = v.pixel(fromCanvas: CGPoint(x: 37, y: 11))
        XCTAssertEqual(p.x, 37, accuracy: 0.0001)
        XCTAssertEqual(p.y, 11, accuracy: 0.0001)
    }

    func testIndependentAxisScales() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertEqual(v.scaleX, 2, accuracy: 0.0001)
        XCTAssertEqual(v.scaleY, 4, accuracy: 0.0001)
        let p = v.pixel(fromCanvas: CGPoint(x: 10, y: 10))
        XCTAssertEqual(p.x, 20, accuracy: 0.0001)
        XCTAssertEqual(p.y, 40, accuracy: 0.0001)
    }

    func testRoundTripIsStableOnAsymmetricPoints() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 1792, height: 1520),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 448, height: 380))
        for point in [CGPoint(x: 3, y: 371), CGPoint(x: 445, y: 7), CGPoint(x: 101, y: 289)] {
            let round = v.canvas(fromPixel: v.pixel(fromCanvas: point))
            XCTAssertEqual(round.x, point.x, accuracy: 0.001)
            XCTAssertEqual(round.y, point.y, accuracy: 0.001)
        }
    }

    func testInputIsClippedToTheImage() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 400, height: 160))
        let low = v.pixel(fromCanvas: CGPoint(x: -50, y: -10))
        XCTAssertEqual(low.x, 0, accuracy: 0.0001)
        XCTAssertEqual(low.y, 0, accuracy: 0.0001)
        let high = v.pixel(fromCanvas: CGPoint(x: 9_999, y: 9_999))
        XCTAssertEqual(high.x, 400, accuracy: 0.0001)
        XCTAssertEqual(high.y, 160, accuracy: 0.0001)
    }

    func testOddPixelDimensions() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 401, height: 161),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 401, height: 161))
        let p = v.pixel(fromCanvas: CGPoint(x: 400, y: 160))
        XCTAssertEqual(p.x, 400, accuracy: 0.0001)
        XCTAssertEqual(p.y, 160, accuracy: 0.0001)
    }

    func testDegenerateBoundsDoNotDivideByZero() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: .zero)
        let p = v.pixel(fromCanvas: CGPoint(x: 10, y: 10))
        XCTAssertTrue(p.x.isFinite && p.y.isFinite)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationViewportTests -quiet 2>&1 | tail -15
```

Expected: FAIL, "cannot find 'AnnotationViewport' in scope".

- [ ] **Step 3: Write the implementation**

Create `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationViewport.swift`:

```swift
import Foundation
import CoreGraphics

/// Maps between a surface's canvas coordinates and source-image pixels.
///
/// Both axes carry their own scale: `.bestResolution` guarantees no fixed
/// relationship between the selection's size and the returned image's size, so a
/// single scalar would be wrong whenever the aspect drifts.
///
/// On the capture surface `canvasBounds` is the pixel size itself, making this the
/// identity; the preview surface exercises the general path.
public struct AnnotationViewport: Equatable, Sendable {

    public let pixelSize: CGSize
    public let canvasBounds: CGRect

    public init(pixelSize: CGSize, canvasBounds: CGRect) {
        self.pixelSize = pixelSize
        self.canvasBounds = canvasBounds
    }

    /// Source pixels per canvas unit.
    public var scaleX: CGFloat {
        guard canvasBounds.width > 0 else { return 1 }
        return pixelSize.width / canvasBounds.width
    }

    public var scaleY: CGFloat {
        guard canvasBounds.height > 0 else { return 1 }
        return pixelSize.height / canvasBounds.height
    }

    /// Canvas point to source pixel, clipped to the image.
    public func pixel(fromCanvas point: CGPoint) -> CGPoint {
        let x = (point.x - canvasBounds.minX) * scaleX
        let y = (point.y - canvasBounds.minY) * scaleY
        return CGPoint(x: min(max(x, 0), pixelSize.width),
                       y: min(max(y, 0), pixelSize.height))
    }

    /// Source pixel back to canvas point.
    public func canvas(fromPixel point: CGPoint) -> CGPoint {
        CGPoint(x: canvasBounds.minX + point.x / scaleX,
                y: canvasBounds.minY + point.y / scaleY)
    }

    /// Converts a screen-constant chrome measurement into source pixels, so
    /// selection outlines and hit tolerances stay the same visual size at any zoom.
    /// Mark geometry must NEVER go through this.
    public func chromeUnits(_ points: CGFloat) -> CGSize {
        CGSize(width: points * scaleX, height: points * scaleY)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationViewportTests -quiet 2>&1 | tail -15
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationViewport.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationViewportTests.swift
git commit -m "feat(annotation): source-pixel viewport with per-axis scale"
```

---

### Task 5: AnnotationPanelGeometry

Extracts the comment panel's dock/flip/clamp math out of the private `screenshotPanelOrigin` so it can be unit-tested, and adds the forced-edge parameter magnification needs. With no forced edge it must be byte-identical to today's behavior, because a second caller outside screenshot mode shares it.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationPanelGeometry.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationPanelGeometryTests.swift`

**Interfaces:**
- Consumes: `StageDockEdge` from Task 3.
- Produces: `AnnotationPanelGeometry.origin(captureRect:panelSize:visibleFrame:margin:clampInset:forcedEdge:) -> (origin: CGPoint, edge: StageDockEdge, isAbove: Bool)`

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationPanelGeometryTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

/// Mirrors `CommentInputWindowController.screenshotPanelOrigin` exactly: three room
/// tests (right, left, above) then an unconditional below fallback, then a clamp.
final class AnnotationPanelGeometryTests: XCTestCase {

    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
    private let panel = CGSize(width: 340, height: 180)

    private func origin(_ rect: CGRect, forced: StageDockEdge? = nil)
        -> (origin: CGPoint, edge: StageDockEdge, isAbove: Bool) {
        AnnotationPanelGeometry.origin(
            captureRect: rect, panelSize: panel, visibleFrame: visible,
            margin: 8, clampInset: 4, forcedEdge: forced)
    }

    func testPrefersRightDock() {
        let r = CGRect(x: 200, y: 400, width: 200, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .leading)
        XCTAssertEqual(o.origin.x, r.maxX + 8)
        XCTAssertEqual(o.origin.y, r.midY - panel.height / 2)
        XCTAssertFalse(o.isAbove)
    }

    func testFallsBackToLeftWhenRightHasNoRoom() {
        let r = CGRect(x: 1200, y: 400, width: 200, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .trailing)
        XCTAssertEqual(o.origin.x, r.minX - 8 - panel.width)
    }

    func testFallsBackToAboveWhenNeitherSideFits() {
        // Spans the width, so neither side has 348pt.
        let r = CGRect(x: 100, y: 100, width: 1300, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .bottom)
        XCTAssertTrue(o.isAbove)
        XCTAssertEqual(o.origin.y, r.maxY + 8)
    }

    func testUnconditionalBelowFallback() {
        let r = CGRect(x: 100, y: 700, width: 1300, height: 150)
        let o = origin(r)
        XCTAssertEqual(o.edge, .top)
        XCTAssertFalse(o.isAbove)
    }

    func testClampKeepsThePanelOnScreen() {
        let r = CGRect(x: 200, y: 870, width: 200, height: 25)
        let o = origin(r)
        XCTAssertGreaterThanOrEqual(o.origin.y, visible.minY + 4)
        XCTAssertLessThanOrEqual(o.origin.y, visible.maxY - panel.height - 4)
    }

    func testForcedEdgeSkipsTheRoomTests() {
        // A magnified rect that would normally flip to a vertical dock keeps its
        // original side when the edge is forced.
        let magnified = CGRect(x: 100, y: 300, width: 1300, height: 320)
        let natural = origin(magnified)
        XCTAssertNotEqual(natural.edge, .leading, "precondition: this rect naturally flips")

        let forced = origin(magnified, forced: .leading)
        XCTAssertEqual(forced.edge, .leading)
        XCTAssertEqual(forced.origin.y, magnified.midY - panel.height / 2)
    }

    func testNilForcedEdgeIsIdenticalToTheUnforcedForm() {
        for rect in [CGRect(x: 200, y: 400, width: 200, height: 80),
                     CGRect(x: 1200, y: 400, width: 200, height: 80),
                     CGRect(x: 100, y: 100, width: 1300, height: 80),
                     CGRect(x: 100, y: 700, width: 1300, height: 150)] {
            let a = origin(rect)
            let b = origin(rect, forced: nil)
            XCTAssertEqual(a.origin, b.origin)
            XCTAssertEqual(a.edge, b.edge)
            XCTAssertEqual(a.isAbove, b.isAbove)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationPanelGeometryTests -quiet 2>&1 | tail -15
```

Expected: FAIL, "cannot find 'AnnotationPanelGeometry' in scope".

- [ ] **Step 3: Write the implementation**

Create `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationPanelGeometry.swift`:

```swift
import Foundation
import CoreGraphics

/// The comment panel's dock/flip/clamp math, lifted out of the private
/// `screenshotPanelOrigin` so it can be tested directly.
///
/// With `forcedEdge == nil` this reproduces the shipped behavior exactly, which
/// matters because the Chrome element-grab path shares the same function.
public enum AnnotationPanelGeometry {

    public static func origin(
        captureRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat,
        clampInset: CGFloat,
        forcedEdge: StageDockEdge? = nil
    ) -> (origin: CGPoint, edge: StageDockEdge, isAbove: Bool) {

        var origin: CGPoint
        var edge: StageDockEdge
        var isAbove: Bool

        func placeLeading() {
            origin = CGPoint(x: captureRect.maxX + margin,
                             y: captureRect.midY - panelSize.height / 2)
            edge = .leading
            isAbove = false
        }
        func placeTrailing() {
            origin = CGPoint(x: captureRect.minX - margin - panelSize.width,
                             y: captureRect.midY - panelSize.height / 2)
            edge = .trailing
            isAbove = false
        }
        func placeBottom() {   // panel ABOVE the selection
            origin = CGPoint(x: captureRect.midX - panelSize.width / 2,
                             y: captureRect.maxY + margin)
            edge = .bottom
            isAbove = true
        }
        func placeTop() {      // panel BELOW the selection
            origin = CGPoint(x: captureRect.midX - panelSize.width / 2,
                             y: captureRect.minY - panelSize.height - margin)
            edge = .top
            isAbove = false
        }

        origin = .zero; edge = .leading; isAbove = false

        if let forcedEdge {
            switch forcedEdge {
            case .leading: placeLeading()
            case .trailing: placeTrailing()
            case .bottom: placeBottom()
            case .top: placeTop()
            }
        } else if captureRect.maxX + margin + panelSize.width <= visibleFrame.maxX {
            placeLeading()
        } else if captureRect.minX - margin - panelSize.width >= visibleFrame.minX {
            placeTrailing()
        } else if captureRect.maxY + margin + panelSize.height <= visibleFrame.maxY {
            placeBottom()
        } else {
            placeTop()
        }

        origin.x = max(visibleFrame.minX + clampInset,
                       min(origin.x, visibleFrame.maxX - panelSize.width - clampInset))
        origin.y = max(visibleFrame.minY + clampInset,
                       min(origin.y, visibleFrame.maxY - panelSize.height - clampInset))

        return (origin, edge, isAbove)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationPanelGeometryTests -quiet 2>&1 | tail -15
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationPanelGeometry.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationPanelGeometryTests.swift
git commit -m "feat(annotation): testable panel dock geometry with forced edge"
```

---

### Task 6: AnnotationItem

The value type every annotation is stored as. Geometry in source-image pixels, top-left origin; fixed sRGB ink so exported pixels do not change with appearance.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationItem.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationItemTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct AnnotationInk: Equatable, Sendable` with `red/green/blue/alpha: CGFloat` and `.presets: [AnnotationInk]`
  - `enum AnnotationTool: String, CaseIterable, Sendable`
  - `enum AnnotationPayload: Equatable, Sendable`
  - `struct AnnotationItem: Identifiable, Equatable, Sendable` with `id`, `payload`, `ink`, `strokeWidth`, `.bounds -> CGRect`

- [ ] **Step 1: Write the failing test**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationItemTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

final class AnnotationItemTests: XCTestCase {

    func testEveryToolHasAStableRawValue() {
        // Raw values are used for tool shortcuts and toolbar state; renaming one
        // silently changes behavior.
        XCTAssertEqual(AnnotationTool.arrow.rawValue, "arrow")
        // select + arrow, line, rect, oval, freehand, highlighter, text, counter,
        // blur, pixelate. Blur and pixelate are separate tools because the spec
        // gives them distinct payloads and distinct redaction semantics.
        XCTAssertEqual(AnnotationTool.allCases.count, 11)
    }

    func testBoundsOfALineCoverBothEndpoints() {
        let item = AnnotationItem(
            payload: .line(from: CGPoint(x: 10, y: 90), to: CGPoint(x: 110, y: 20)),
            ink: .presets[0], strokeWidth: 4)
        XCTAssertEqual(item.bounds.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.minY, 20, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.maxX, 110, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.maxY, 90, accuracy: 0.0001)
    }

    func testBoundsOfAFreehandCoverEveryPoint() {
        let item = AnnotationItem(
            payload: .freehand(points: [CGPoint(x: 5, y: 5),
                                        CGPoint(x: 80, y: 12),
                                        CGPoint(x: 33, y: 61)]),
            ink: .presets[0], strokeWidth: 2)
        XCTAssertEqual(item.bounds, CGRect(x: 5, y: 5, width: 75, height: 56))
    }

    func testFreehandWithNoPointsHasEmptyBounds() {
        let item = AnnotationItem(payload: .freehand(points: []), ink: .presets[0], strokeWidth: 2)
        XCTAssertTrue(item.bounds.isEmpty)
    }

    func testInkPresetsAreFixedAndOpaque() {
        // Exported ink must not vary with light/dark mode, so presets are literal
        // sRGB rather than appearance-adaptive tokens.
        XCTAssertFalse(AnnotationInk.presets.isEmpty)
        for ink in AnnotationInk.presets {
            XCTAssertEqual(ink.alpha, 1, accuracy: 0.0001)
        }
    }

    func testHighlighterInkIsTranslucent() {
        XCTAssertLessThan(AnnotationInk.highlighter.alpha, 1)
    }

    func testItemsWithIdenticalContentAreEqualButHaveDistinctIDs() {
        let a = AnnotationItem(payload: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                               ink: .presets[0], strokeWidth: 2)
        let b = AnnotationItem(payload: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                               ink: .presets[0], strokeWidth: 2)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.payload, b.payload)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationItemTests -quiet 2>&1 | tail -15
```

Expected: FAIL, "cannot find 'AnnotationItem' in scope".

- [ ] **Step 3: Write the implementation**

Create `app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationItem.swift`:

```swift
import Foundation
import CoreGraphics

/// Fixed sRGB ink. Deliberately NOT a `remarc*` appearance token: those adapt to
/// light and dark mode, which would make exported pixels depend on the appearance
/// the editor happened to be in. Brand tokens style the toolbar chrome only.
public struct AnnotationInk: Equatable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static let presets: [AnnotationInk] = [
        AnnotationInk(red: 0.90, green: 0.16, blue: 0.22),   // red
        AnnotationInk(red: 0.99, green: 0.69, blue: 0.11),   // amber
        AnnotationInk(red: 0.16, green: 0.71, blue: 0.42),   // green
        AnnotationInk(red: 0.15, green: 0.47, blue: 0.95),   // blue
        AnnotationInk(red: 0.10, green: 0.10, blue: 0.11),   // near-black
        AnnotationInk(red: 1.00, green: 1.00, blue: 1.00)    // white
    ]

    public static let highlighter = AnnotationInk(red: 0.99, green: 0.90, blue: 0.20, alpha: 0.4)
}

public enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, line, rect, oval, freehand, highlighter, text, counter, blur, pixelate
}

/// One payload per tool. All geometry is in SOURCE-IMAGE PIXELS with a top-left
/// origin, never in view points, so zoom can never reach it.
public enum AnnotationPayload: Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case oval(CGRect)
    case freehand(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case text(String, at: CGPoint, pointSize: CGFloat)
    case counter(Int, at: CGPoint, radius: CGFloat)
    case blur(CGRect)
    case pixelate(CGRect)
}

public struct AnnotationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var payload: AnnotationPayload
    public var ink: AnnotationInk
    public var strokeWidth: CGFloat

    public init(id: UUID = UUID(), payload: AnnotationPayload, ink: AnnotationInk, strokeWidth: CGFloat) {
        self.id = id
        self.payload = payload
        self.ink = ink
        self.strokeWidth = strokeWidth
    }

    /// Tight geometric bounds in source pixels, before stroke width. The compositor
    /// widens this by the stroke when computing a dirty rect.
    public var bounds: CGRect {
        switch payload {
        case let .arrow(from, to), let .line(from, to):
            return Self.box(covering: [from, to])
        case let .rect(r), let .oval(r), let .blur(r), let .pixelate(r):
            return r.standardized
        case let .freehand(points), let .highlighter(points):
            return Self.box(covering: points)
        case let .text(_, at, pointSize):
            return CGRect(x: at.x, y: at.y, width: 0, height: pointSize)
        case let .counter(_, at, radius):
            return CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    private static func box(covering points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/AnnotationItemTests -quiet 2>&1 | tail -15
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Run the whole suite to confirm nothing regressed**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -quiet 2>&1 | tail -20
```

Expected: PASS, with the four new test classes included.

- [ ] **Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Annotation/AnnotationItem.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/AnnotationItemTests.swift
git commit -m "feat(annotation): item value type with fixed sRGB ink"
```

---

## Phase 1 exit criteria

- Both spikes have recorded verdicts in the spec, replacing their "unverified" wording.
- Four new modules exist under `Annotation/`, none importing AppKit views.
- 32 new unit tests pass, and the existing suite still passes.
- The `Remarc` app target still builds.

If Spike A fails, stop: the freeze step needs redesign before Phases 3 and 5 mean anything. If Spike B fails, continue - the fallback is contained to the parent-view gating table - but record it, because Phase 5's gating table changes.
