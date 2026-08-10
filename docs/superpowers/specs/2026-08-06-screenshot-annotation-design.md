# Screenshot Annotation - Audited Design

Date: 2026-08-06
Status: Implementation-ready after four adversarial source-review rounds
Audit baseline: `main` at `26fa725`. Every citation below was opened at the cited lines against that commit.

**Baseline warning.** `main` moved twice during this spec's authoring: `770baa0` merged the wake-on-comment data-integrity layer (adding `DocumentLock`, `AppStateMerge`, `wakeRequested`, and the `orphanedImages` retention pass), and `26fa725` rebased the merge baseline on reload. `ScreenCaptureService.swift` was untouched by both, so all capture-side citations are stable, but every persistence and comment-UI citation in revisions 2 and 3 was stale. If the persistence layer is still in flight, re-verify this spec's persistence section before implementing rather than assuming these line numbers hold.

## Outcome

Add screenshot annotation to both Remarc surfaces with one shared document model and one shared source-resolution composite:

1. **During capture**: an Annotate control freezes the selected pixels and places an AppKit drawing canvas directly inside the selected region while the comment panel remains available. When the region is small, the frozen bitmap is displayed **magnified** so there is room to draw, with the comment panel following so the two keep the same relative positioning.
2. **In screenshot preview**: the same canvas over any stored primary screenshot or attachment. Applying changes atomically replaces the app-owned PNG; Save As remains a separate export action.

The visible capture flow stays region selection -> comment -> save when annotation is never entered. Internally the save transaction changes so image generation can fail without destroying the overlay, comment draft, or annotation session, and so a comment counts as saved only once it is durably on disk **through the cross-process merge protocol**.

## Locked product scope

- Both surfaces ship together.
- V1 tools: arrow, line, rectangle, oval, freehand pen, highlighter, text, counter badge, blur, pixelate, selection, undo/redo, fixed annotation colors, three stroke-width presets. No crop, no spotlight.
- Applying/saving annotations flattens them into PNG pixels. Vectors are session-only; saved marks are not re-editable.
- Capture-time annotation stays anchored to the selected region; it does not open a separate editor window.
- Region resizing is locked while a frozen capture annotation session exists.
- **Magnification is display-only.** The exported PNG is always exactly the source pixel dimensions.
- BetterShot and Snapzy may be ported selectively only after a pinned local checkout confirms the expected BSD-3-Clause license.
- Blur and pixelate are visual-obscuration tools, **not security-grade redaction**.

## Verified current code constraints

| Current behavior | Source evidence | Design consequence |
|---|---|---|
| Capture is deferred until the comment save callback. The overlay intentionally remains after selection. | `startCapture` `ScreenCaptureService.swift:526-551` (only calls `showOverlay()`); the single lexical `commitCapture` call is `CommentInputWindowController.swift:311` | Freeze is opt-in; the non-annotation path still takes its first image at save time. |
| The selection surface is a raw AppKit `RegionSelectionView`. It owns all selection interaction. | private `ScreenCaptureService.swift:9`; `showOverlay` `:555-631`, view created `:579`, installed `:593-594`; mouse machine `:194-320`; cursor rects `:334-368`; tracking `:370-386`; handles `:86-152`; size label `:154-190` | Six parent behaviors must be gated: the mouse methods, `resetCursorRects`, handle drawing, the size-label anchor, the `draw(_:)` chrome rect, and `handleRegionMoved`. |
| Panel ladder: overlay `.screenSaver`, comment panel `.screenSaver + 1`, fly panel `.screenSaver + 2`. | `ScreenCaptureService.swift:572`; `CommentInputWindowController.swift:54`, `:421`, `:689-699` | The annotation toolbar takes `.screenSaver + 2` and is ordered out before the fly panel reuses it. The canvas is a subview, so it needs no slot. |
| The final capture uses `CGWindowListCreateImage(... .optionOnScreenBelowWindow ...)` against the overlay's `windowNumber`. | `captureRegion` `ScreenCaptureService.swift:748-764`; `saveImage` `:770-791`; overlay WID `:704-709` | Anything drawn inside the overlay is automatically excluded from the saved capture. |
| **`CGWindowListCreateImage` is unavailable, not merely deprecated, from macOS 15 onward.** The app compiles only because its deployment target is macOS 14. | `Package.swift:7` pins `.macOS(.v14)`. Measured: `swiftc` at the host target fails with `'CGWindowListCreateImage' is unavailable in macOS: Please use ScreenCaptureKit instead`; the same source with `-target arm64-apple-macos14.0` compiles with a deprecation warning only | Raising the deployment target to 15 breaks `ScreenCaptureService` outright. This design adds a **second** call site (the freeze grab), doubling the surface a future `ScreenCaptureKit` migration must cover. Keep both calls behind `captureRegion` so the migration has exactly one seam, and treat a deployment-target bump as blocked on that migration rather than a routine change. |
| Remarc implements **no** `applicationShouldTerminate` and does not set `NSSupportsSuddenTermination`. | no match for either symbol anywhere under `app/RemarcPackage/Sources/RemarcFeature/` or Remarc's own `Info.plist` | The durable-quit path in the capture transaction cannot just "defer termination": the delegate method has to be added, and `NSSupportsSuddenTermination` must be set to `false`, or macOS may kill the process without ever calling it. |
| `pendingQuartzRect` is the only rect reaching the **below-overlay final capture**; the fly path builds its own `quartzCaptureRect`. | written only by `updatePendingCapture` `ScreenCaptureService.swift:663-675`, consumed `:699`, `:718`; fly rect `CommentInputWindowController.swift:405-411`, used `:435-440` | Magnification must never write `pendingQuartzRect`. The fly path's independent rect is removed by this design. |
| `commitCapture` clears pending state and dismisses the overlay before/while saving, returns only success, reports failures to Sentry, and copies to the clipboard when the preference is on. | `ScreenCaptureService.swift:698-737`: guard `:699-702`, clear `:714-715`, `dismissOverlay()` `:719` before `saveImage` `:720`, clipboard `:722-724`, `onComplete` `:728`, Sentry `:733-735` | Replace with a prepare/finalize transaction. **Preserve the Sentry reporting and the clipboard behavior**, the latter gated on durable success. |
| `commitCapture` is reached through **two scheduling branches of one call**. | closure `CommentInputWindowController.swift:310-344`, call `:311`; branches `:471` and `:476`; `showForScreenshot` always sets `screenshotSelectionRect`, so the no-rect branch is defensive | Both branches route through the same transaction; only the presence of a fly panel differs. |
| The fly animation takes a separate `.optionOnScreenOnly` grab in the same runloop turn that merely *starts* the 0.15s overlay fade. | grab `CommentInputWindowController.swift:435-440`; fade started `:385-393`; layer `:441-448` with `contentsGravity = .resizeAspectFill` | Prepare the final image before teardown and animate that exact image. Use `.resize`. |
| **`createComment` never proves durable success on either branch.** It auto-creates a session, mutates memory, then either debounces (`scheduleSave`) or, when `wakeRequested`, calls synchronous `saveNow()`. Both reach `saveToDisk`, which swallows every error including a lock timeout. Its only `nil` return is guarded by a session created moments earlier. | `PersistenceManager.swift:296-341` (auto-create `:298-302`, `nil` guard `:307-310`, append/counter `:327-328`, wake branch `:330-336`, webhook `:338`); `saveToDisk` `:538-564` swallows at `:556-563`; `saveNow` `:570-572` | A non-`nil` return cannot finalize the capture. A `Result`-returning durable entry point is required, and it must describe both branches. |
| Persistence is **multi-writer**. Every write re-reads under a cross-process lock and three-way merges against `lastPersisted`. | `saveToDisk` `:538-564`; lock `DocumentLock.swift:26-31`, timeout `:15`, stale reclaim `:58-78`; merge `AppStateMerge.swift:19-53`; baseline `PersistenceManager.swift:14`, adopted on reload `:602` | A durable write **must** go through the same reread/merge/lock path. Writing a staged candidate directly would erase MCP and hook commits. |
| `totalCommentsCreated` is part of the encoded `AppState`, and the merge resolves it by `max`. | property `AppState.swift:7`, unconditionally encoded by the hand-written `encode(to:)` at `:74` (the type omits some fields, so the encode is the proof); merge `AppStateMerge.swift:48-51`; increment `PersistenceManager.swift:328` | The counter increment must be inside the candidate before the write, never applied afterwards. |
| Expired comments are pruned while their images are deliberately retained in `appState.orphanedImages` until a separate image-retention cutoff. | prune/orphan pass `PersistenceManager.swift:776-789`; retention pass `:794-802` | Those files have **no** comment or attachment reference. A sweep keyed on "unreferenced" would delete them early. |
| Attachments are written to disk before any comment references them and can stay draft-held indefinitely. | `CommentInputView.swift:39`, `:336` calling `PersistenceManager.saveAttachmentImage` | A directory-scan sweep would delete a user's pending attachment. |
| Browser screenshots request region context at show and again at save, then consume it inside the post-animation closure. Consumption clears the singleton. | `CommentInputWindowController.swift:151-159`, `:300-308`, `:315-318`; `WebSocketService.swift:126-149`, `:525-596` | Retain consumed values somewhere the UI can read. |
| The web-context badge prefers controller state and falls back to the singleton. | `CommentInputView.swift:212` | Restoring a failed save must republish retained context through controller state. |
| The screenshot comment text view is made first responder; Command-A is Select All and Command-Z is text undo. | `makeCommentPanelKey` `CommentInputWindowController.swift:674-687` (first responder `:683`); `show` `:701-807`; `CommentTextEditor.swift:89-103`, `:144-177` | Unmodified `A` cannot be the entry shortcut and plain Command-A is taken. |
| **Capture entry is unguarded.** Both entry points call `startCapture` directly, and it overwrites callbacks and pending state before creating another overlay. | `GlobalHotkey.swift:222`; `PopoverContentView.swift:250`; `startCapture` `ScreenCaptureService.swift:526-551`; `showOverlay` `:555-631` | A second capture during an in-flight save can strand the first transaction. The guard must live in the service, not only in a controller wrapper. |
| Save and dismiss are directly callable from the comment UI while the 0.4s choreography runs, and the choreography removes the height observer and click-outside monitor. | save `CommentInputView.swift:86`; wake `:95`; close `:115`; teardown `CommentInputWindowController.swift:351-353` | The transaction gate must cover save, wake-save, and dismiss, and restoration must reinstall both the height observer and the monitor. |
| `saveComment` carries `wakeRequested` across the whole asynchronous fly sequence. | `CommentInputWindowController.swift:275`; consumed at creation `:325-336` | `CaptureSaveDraft` must retain it, and both Save and Wake Save need success and restore coverage. |
| Both Escape monitors installed by `showOverlay` are removed the moment a region is finalized. | monitors `ScreenCaptureService.swift:609-623`; `removeEscapeMonitor()` is the first statement of `handleRegionSelected` `:678` | During the comment/annotation phase they no longer exist. Do not gate them. |
| `KeyablePanel.cancelOperation` branches on `autoSaveCountdownActive`, gated by a policy requiring `isVoiceInvoked`, which screenshots set false. | `CommentInputWindowController.swift:9-15`; `VoiceAutoSavePolicy.swift:3-13`; `CommentInputWindowController.swift:141` | Unreachable in screenshot mode, but `KeyablePanel` is shared with the voice path. Add an annotation branch ahead of the existing two. |
| `repositionForScreenshot` **always** rebuilds the VEV mask on the `restoreFocus == true` path; only the live-drag path skips it. | `CommentInputWindowController.swift:663-670` | The new entry point rebuilds unconditionally so the drag-path skip can never apply. |
| `screenshotPanelOrigin` is private, has **three** room tests plus an unconditional fallback, and has a second caller outside screenshot mode. | `CommentInputWindowController.swift:615-646`: margin `:618`, tests `:624`, `:628`, `:632`, fallback `:636`, clamp `:642-643`; second caller `:758` | Extract the math into an internal pure type; any signature change must default to byte-identical behavior for the Chrome element-grab caller. |
| Preview is a keyable, resizable, borderless `NSPanel` at `.popUpMenu + 3` hosting SwiftUI in an `NSVisualEffectView`. | `ScreenshotPreviewController.swift:5-13`, `:49`, `:53`, `:60`, `:63-72`, `:94` | Off the `.screenSaver` ladder; never interacts with the capture stack. |
| Preview's download button is labeled **"Save Image"**, writes with `try?`, and dismisses unconditionally before checking the response. | `ScreenshotPreviewController.swift:192-202` (`.help("Save Image")` `:200`); `saveImage` `:108-128` (`dismiss()` `:121`, guard `:123`, `try?` `:125`) | Rename to "Save As..." (a copy change) and add a distinct Apply action. |
| Primary screenshots open preview from `CommentCardView` and `CommentEditorView`; attachments from `AttachmentStripView`. `HistoryCardView` has no tap action. | `CommentCardView.swift:102-112`; `CommentEditorView.swift:27-34`; `AttachmentStripView.swift:27-33`; `HistoryCardView.swift:61-64`, `:18` | Add the missing action. Three existing entry points, not four. |
| Thumbnails call `loadScreenshotImage` synchronously from `body`; no revision state exists. | `ScreenshotThumbnailView.swift:4-55` (call `:13`); `Constants.swift:29-44` | Add a runtime path-revision signal and byte reload. |
| `ToastManager` is `@Observable` and `ToastOverlay` is mounted only in the menu-bar popover, dismissed before capture starts. | `ToastView.swift:3-32`, `:34-67`; `PopoverContentView.swift:166-172`, `:250` | Mount locally on both annotation surfaces; read `currentToast` inside a SwiftUI `body`. |
| `ConfirmationButton` is one styled button. | `ConfirmationButton.swift:3-70`; two-instance usage `HistoryCardView.swift:117-142` | Build inline discard UI from two instances. |
| Brand colors adapt to appearance; material comes from AppKit VEV; DESIGN.md forbids SwiftUI material over it. | `Colors.swift:13-29`, `:137-163`; `MenuBarPopoverController.swift:131-144`; `DESIGN.md:47` | `remarc*` for chrome only; fixed sRGB for exported ink. |
| `NSImage.pngData()` round-trips through TIFF and is the app's only PNG encoder. | `PanelMask.swift:3-10` | The new renderer produces a `CGImage` and uses `NSBitmapImageRep(cgImage:)` only to encode. |
| `RegionSelectionView` is unflipped, does not opt into layer backing, and currently adds no subviews. AppKit draws parents before subviews. | `ScreenCaptureService.swift:9`; border stroked `:71-75` | The canvas is the first subview this design adds, and it must draw the selection border itself or it will cover the stroke's inner half. **`layer == nil` is not the invariant** - measured 2026-08-06, AppKit gives every view in a window an implicit `NSViewBackingLayer` regardless. The invariant that actually holds, and the one to assert, is `wantsLayer == false` plus an unchanged backing-layer identity across `addSubview`. |

## Shared annotation document

`AnnotationSession` is a `@MainActor final class` conforming to `ObservableObject`, holding: the immutable source `CGImage` and its measured `pixelSize`; `[AnnotationItem]` with selection, tool, color, stroke preset, counter seed, undo/redo, dirty state; the current **generation** number; the published composite and pending patch it displays; and an optional inline-text draft. It does **not** own the filter or composite caches; those belong to the compositor actor (see Compositor concurrency), and each session has exactly one compositor.

Ownership: `ScreenCaptureService` owns the capture session, canvas, stage state, and toolbar panel, exposing `beginAnnotation()`, `requestAnnotationExit()`, `setZoom(_:)`, `prepareCommit()`, `finalize(token:)`, `restore(token:)`. `prepareCommit()` takes no session argument; it consumes service-owned state and returns a typed `PrepareOutcome`: `.success(PreparedCapture)` or `.failure(CaptureError, cleanup: PreparedPartial?)`. It does not `throw`, because a thrown error cannot carry the partial resource a failed prepare may have created (a lease with no file, or a file with a lease); the failure case hands that partial to `concludeTransaction`, which routes it to `restore`. `finalize` and `restore` are the **only** lease owners and exactly one of them runs, so no caller ever removes a lease itself. `CommentInputController` owns the key monitor, comment draft, transaction state, and dismissal coordinator. `ScreenshotPreviewController` owns an independent preview session. All callbacks capture owners weakly.

All committed geometry is in **source-image pixel coordinates, top-left origin**. Selection handles, hover state, gesture state, and zoom are editor UI and are never exported.

### Inline-edit resolution

Two distinct APIs, because a Boolean cannot distinguish commit from cancel:

- `commitActiveEditForOutput() throws` - commits a pending label or throws. It **never silently cancels**. Required before any compositor or output render: prepare, Copy, Apply, Save As.
- `resolveActiveEdit(for: DismissalIntent) -> EditResolution` - returns `.committed`, `.cancelledAndConsumed`, or `.blocked`.

Ordinary canvas redraws are **not** gated on either; the canvas repaints freely while the inline `NSTextField` is active.

Undo checkpoints are created on completed gestures, text commit, delete, style mutation, counter placement, and z-order mutation. Zoom, selection, and focus are excluded. Bound history to 100 checkpoints.

## Coordinate and image contract

Nothing derives from an assumed Retina multiplier and no code path defaults a backing scale. Backing figures come from AppKit conversion, never arithmetic on a raw `backingScaleFactor`.

Per session: `pixelSize` is **measured** from the decoded or captured `CGImage`, never computed from points and never assumed to equal `selectionSize * backingScale` - `.bestResolution` guarantees no such relationship.

`canvas.bounds = CGRect(origin: .zero, size: pixelSize)`, a session constant independent of backing, so `AnnotationViewport` is bit-identical for the life of the session and a backing change cannot rebuild it. On the capture surface the viewport is the identity; the general path is exercised by the preview surface and its tests.

Presets (stroke, arrowhead, counter, text) resolve to source pixels once and never change with panel resize or stage zoom.

Output is always exactly `pixelSize`, reusing the source color space when Core Graphics supports it and otherwise sRGB.

## Rendering architecture

| File | Responsibility |
|---|---|
| `Annotation/AnnotationItem.swift` | Source-pixel geometry and fixed-color style values. |
| `Annotation/AnnotationSession.swift` | Observable UI state, undo/redo, generation, published composite and pending patch, lifecycle. Owns no caches. |
| `Annotation/AnnotationViewport.swift` | Tested transforms between source pixels and canvas bounds. |
| `Annotation/AnnotationStageGeometry.swift` | Pure magnification math: allowance box, fit zoom, auto zoom, aligned origin interval, `(effectiveZoom, rect)`. |
| `Annotation/AnnotationPanelGeometry.swift` | Pure extraction of the comment-panel dock/flip/clamp math. |
| `Annotation/AnnotationRenderer.swift` | Draws items into a `CGContext` at one unit per source pixel. |
| `Annotation/AnnotationCompositor.swift` | Committed and transient source-resolution rasters, generation-numbered. |
| `Annotation/AnnotationFilters.swift` | Core Image blur/pixelate from the immutable source. |
| `Annotation/AnnotationCanvasNSView.swift` | Flipped canvas: input, hit testing, chrome, inline `NSTextField`, raster compositing. |
| `Annotation/AnnotationCanvasRepresentable.swift` | `NSViewRepresentable` for preview. |
| `Annotation/AnnotationToolbarView.swift` | Toolbar with hover/pressed states, zoom stepper, inline discard, local toast. |
| `Annotation/AnnotationToolbarPanelController.swift` | `KeyableAnnotationPanel` with its own `cancelOperation`. |
| `Annotation/AnnotationExporter.swift` | Encodes a composite `CGImage` to PNG; typed errors; no `lockFocus`. |
| `Annotation/PreparedCaptureLease.swift` | Records in-flight prepared capture paths for crash reconciliation. |
| `Annotation/StoredImageRevisionCenter.swift` | Runtime-only revision signal keyed by relative path. |

### Two rasters, both at source resolution

Drawing vectors into the canvas's display context cannot match export once magnified: AppKit rasterizes strokes, text, and antialiased edges at the enlarged backing resolution while export rasterizes at one output pixel per source pixel. So neither surface draws committed vectors directly.

- **Committed raster**: the full composite (base image, filters, all committed items) rendered into a `pixelSize` `CGImage`, tagged with a generation number. Rendered **off the main actor**; the session publishes it when it arrives.

  `AnnotationSession` and the owning `ScreenCaptureService` (`ScreenCaptureService.swift:501-502`) are both `@MainActor`, so the render is submitted to the compositor actor rather than sharing state. A result whose generation is older than the published one is ignored, so a slow render cannot overwrite a newer composite.

- **Pending patch**: a source-resolution **opaque replacement patch**, not a transparent overlay.

The canvas draws the committed raster, then blits the pending patch over its rect with copy semantics, then editor-only chrome, then the selection border. Both scale through the identical transform, so a mark does not shift when it commits.

A transparent overlay is only capable of representing *newly added* marks. The session also supports moving, deleting, restyling, and reordering already-published items (undo checkpoints cover all four), and an overlay cannot express any of them: the old pixels stay visible underneath until the full render lands, and a deletion has nothing to draw at all.

So the patch is defined as a region, not a list of new marks:

- Its rect is the **union of the old and new dirty bounds** of everything changed since the published generation.
- It is rendered from the immutable base plus **every current item intersecting that rect**, in global z-order, exactly as the compositor would render them.
- It is composited as a replacement of that rect, so removing or moving a published mark erases it immediately.

It is generation-tagged, and it is discarded only when a published composite already contains every change it represents. Because it is re-rendered from the current item list rather than accumulated, rapid back-to-back gestures and out-of-order render completion both stay correct.

### Compositor concurrency

`AnnotationCompositor` is an `actor` that owns the filter and composite caches outright. They move off `AnnotationSession`, which stays `@MainActor` for UI state only; two owners for one cache is what makes coalescing and eviction unspecifiable. There is exactly one compositor per session, so no job, waiter, or cache is ever shared between the capture and preview surfaces.

**Actor isolation alone does not give the one-render invariant.** Swift's own concurrency guide is explicit that "actors do not guarantee atomicity across suspension points": if a render method suspends, another submission can enter the actor and interleave. So the invariant is enforced by state, not by the actor keyword:

- The render body performs its Core Graphics work in a `nonisolated` synchronous function. It takes an immutable snapshot in and returns a `CGImage`; it contains no `await`, so it cannot be interleaved partway through.
- The actor holds an explicit `inFlight: Generation?`. A submission arriving while one is in flight records itself as the single pending generation, replacing any earlier pending one, and returns; it does not start a second render.
- When the in-flight render completes, the actor publishes it and then starts the pending generation if there is one.

That gives at most one running render and at most one queued generation, which is what the memory bound assumes. Writing `serial actor` and expecting the runtime to provide this would be wrong.

- **Handoff.** The main actor snapshots `(source, items, generation)` and submits it. `CGImage` is already `@unchecked Sendable` in the SDK (`CoreGraphics.swiftinterface`: `extension CoreGraphics.CGImage : @unchecked Swift.Sendable`), so it passes directly with no bespoke box; every other snapshot member must be a genuinely `Sendable` value type.
- **Coalescing.** Submitting generation N supersedes any queued generation below N that has not started. At most one render runs and at most one waits; intermediate generations are dropped rather than rendered and discarded.
- **Failure delivery.** A render failure resumes **every** waiter with that failure, so no waiter is left suspended.
- **Memory.** The cap is a **total across every raster and cache on both surfaces**, not a per-item estimate: source image, filter derivatives, published composite, in-flight composite, and pending patch. Two full `pixelSize` rasters at 5120x2880 BGRA are already about 112 MiB, so the source and filter caches must be counted and the cap enforced by evicting filter derivatives first, then refusing to start a new render until the in-flight one completes. A budget that omits the caches is an estimate, and this one is meant to be enforceable.

**Output barrier.** Export, prepare, Copy, and Apply do not chase a moving target. They take a **scoped freeze token** that suspends canvas mutation, which fixes the newest generation, then await `publishedGeneration >= targetGeneration`. Because mutation is frozen the target cannot advance, so the wait terminates. Awaiting "whichever generation is current" could starve while the user keeps drawing; awaiting a fixed generation without freezing could hang once superseded.

The token thaws on **every** exit: success, render failure, task cancellation, a Save As sheet the user cancels, and a preview dismissed mid-export. A freeze that survives its operation leaves the canvas permanently read-only, which is why the token is scoped rather than a bare flag.

**Revised during implementation.** The original claim was that the committed source raster is the same object on screen and in the file. Building it that way produced visibly jagged marks: on a 4x stage every stroke, arrowhead, and letter was rasterized at a quarter of its displayed size and then blown up. The base image cannot gain detail at any setting - it has the pixels it has - but the marks drawn over it can be rasterized at the resolution they are shown at, and now are.

So the renderer takes a `scale`. The editor renders at the display's device-pixel ratio; **export always renders at exactly `pixelSize`** through `AnnotationCompositor.renderForOutput`, which never touches the published display raster. The transient drag patch takes the same scale as the committed raster, or a stroke is jagged under the cursor and snaps crisp at mouse-up.

The parity claim is therefore narrower, and the tests assert the narrower version: **both rasters come from the same renderer and the same item list, and the file is always exactly the source pixel dimensions.** Literal display-pixel parity was never achievable and the same-object form is no longer claimed.

Budgets, because captures are unrestricted `.bestResolution` images (`ScreenCaptureService.swift:748-764`): a 5120x2880 BGRA raster is roughly 56 MiB before source and filter caches. A full-frame composite per mouse event is untenable, which is why the transient path is dirty-rect scoped and the committed path is off-main. Record a target of one full committed render under 250ms at 5K and no main-thread work per drag event beyond the dirty rect.

Item order is a **single global list**: each item, filter or vector, is drawn at its own z position, and filters always sample the immutable base rather than already-annotated pixels. This preserves the z-order mutations that undo already records. There is no filters-first stratum.

**Filter geometry and cache keys are defined in image space and must never include a zoom factor**; a redaction that looks opaque on a magnified stage but under-redacts in the file is a privacy defect.

Remarc targets macOS 14 (`Package.swift:7`). Core Graphics, Core Image, and AppKit only.

## Capture-time flow

### Enter and freeze

1. An **Annotate** pill docks to the selection edge opposite the comment panel, with hover, pressed, focus, and selected states.
2. Entry is **Shift-Command-A** via a screenshot-mode local key monitor, so it works while the comment text view is first responder without stealing plain Command-A.
3. Entry is gated on `panelLayoutReady`, published once the deferred `updatePanelHeight()` has run (`show()` schedules height work asynchronously and first-responder work later still). The pill is disabled until then.
4. Entry is also gated on the capture transaction being `.idle`.
5. Freeze grabs the region with the same `.optionOnScreenBelowWindow` semantics as the final capture and stores the `CGImage` and its measured pixel size.
6. On failure, remain in live selection, retain the typed comment, and show a local toast.
7. On success, lock region geometry, add the canvas, set `annotationActive = true`, and compute the stage in the same synchronous pass.

The toolbar is a nonactivating keyable `NSPanel` with an `NSVisualEffectView(material: .popover)` content view and `remarcBackgroundGradient(for:)`, no SwiftUI material. It implements its own `cancelOperation`.

Panel order: overlay and canvas `.screenSaver`; comment `.screenSaver + 1`; toolbar `.screenSaver + 2`; fly border at the same raw level, created only after the toolbar is ordered out.

### Parent-view behaviors that must be gated

| Site | Today | While a session exists |
|---|---|---|
| `draw(_:)` dim fill `:58-61` | `black 0.5` over `bounds` | unchanged |
| `draw(_:)` guard `:63` | `currentSelectionRect` | the display rect `D` |
| `draw(_:)` `.clear` cutout `:67-69` | punches the selection | **skipped**; a clamped `D` may not cover `S`, and a cleared sliver would show undimmed desktop |
| `draw(_:)` border `:71-75` | parent strokes it | **not drawn by the parent**; the canvas draws it after its rasters |
| `drawSizeLabel(for:)` `:154-190` | one rect for text and position | split: text from `S`, position/flip/clamp from `D` |
| `drawHandles` `:81-83`, `:86-152` | drawn when idle | **skipped**; resize is locked, so the chrome constants at `:42-47` need no zoom compensation |
| `resetCursorRects` `:334-368` | crosshairs and resize strips | **returns immediately**; the canvas owns its cursor |
| `mouseDown/Dragged/Up` `:194`, `:220`, `:245` | selection machine | early-return |
| `handleRegionMoved` `:688-693` | writes `pendingQuartzRect` | early-return with a debug log |
| `updateTrackingAreas` `:370-382`, `mouseMoved` `:384-386` | tracking and invalidate | unchanged; harmless once cursor rects are empty |
| `cornerHitTest`, `edgeHitTest`, `computeEdgeResize`, `rectFromDrag` | - | untouched; unreachable |

### Exit, discard, and dismissal

Teardown happens at exactly one point: the completion handler of the exit animation. The canvas stays installed and the anchor stays set for the 0.14s collapse, with input disabled. Nothing is cleared synchronously at the start of exit.

Every user-initiated dismissal routes through one coordinator, which **resolves exactly one layer per invocation and stops**:

1. If an inline text edit is active, `resolveActiveEdit(for:)` consumes the event and returns focus to the canvas. Nothing further happens on that keystroke.
2. Otherwise, if the toolbar has focus, focus returns to the canvas and the event is consumed there.
3. Otherwise, if a dirty annotation session exists, discard controls are revealed.
4. Otherwise the capture is cancelled.

The close button (`CommentInputView.swift:115`) routes here instead of calling `dismiss()` directly. `KeyablePanel.cancelOperation` gains an annotation branch **ahead of** its existing `autoSaveCountdownActive` branch (`CommentInputWindowController.swift:9-15`), which stays intact for the shared voice path.

| Focus/state | Letters | Command-Z | Delete | Escape |
|---|---|---|---|---|
| Comment text view, annotation off | Types; Command-A is Select All; Shift-Command-A enters annotation | Text undo | Edits text | Coordinator -> capture cancel |
| Annotation canvas | Tool shortcuts, `A` = arrow | Session undo | Deletes selection | Coordinator -> discard controls or exit |
| Inline `NSTextField` | Types | Field undo | Edits text | Consumed: cancels the edit, returns to canvas |
| Annotation toolbar | Key navigation | No session undo | No deletion | Consumed: returns focus to the canvas |
| Discard controls shown | Toolbar navigation | No mutation | No mutation | Hides discard controls, stays in annotation |

## Capture-time magnification

The motivating case: a 200 x 80 region has too little room to place an arrowhead. Magnification enlarges the frozen bitmap on screen while the comment panel follows, over the unchanged dim backdrop.

**Prior-art note.** No surveyed product does canvas zoom on a capture overlay; CleanShot X, Snagit, Shottr, and Zight zoom inside an editor window, Apple Markup ships no canvas zoom, and Snapzy put zoom only in its windowed editor, not its inline surface. That constraint comes from the selection being a live cutout, which freeze-on-toggle removes. Auto-magnification on entry is likewise novel. Both are deliberate.

### Coordinate contract

```
override var isFlipped: Bool { true }                    // top-left origin

override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    bounds.size = pixelSize                              // RE-ASSERT: see below
}
```

**`bounds` is only a session constant if it is re-asserted after every frame change.** Setting `bounds` to a size different from `frame` does not pin the coordinate system; it establishes a *scale factor* that AppKit then preserves across subsequent frame changes. Measured directly:

```
bounds = 400x160 while frame = 200x80        -> frame 200x80,  bounds 400x160   (2x factor recorded)
then frame = 800x320  (the z=4 display rect) -> frame 800x320, bounds 1600x640  (factor preserved)
convert(frame bottom-right) -> (1580, 40)                       expected (400, 160)
```

So the naive form multiplies the canvas coordinate system by `z` on every zoom, and every stored annotation coordinate would be wrong by that factor. Overriding `setFrameSize` to restore `bounds.size = pixelSize` fixes it, verified at every ladder step:

```
z=1 frame 200x80    bounds 400x160   topLeft (0,0)  bottomRight (400,160)
z=2 frame 400x160   bounds 400x160   topLeft (0,0)  bottomRight (400,160)
z=4 frame 800x320   bounds 400x160   topLeft (0,0)  bottomRight (400,160)
z=8 frame 1600x640  bounds 400x160   topLeft (0,0)  bottomRight (400,160)
```

Only with that override is `AnnotationViewport` genuinely bit-identical across zoom changes, which is the property the rest of this design leans on. A unit test must assert `bounds.size == pixelSize` after each ladder step, not merely at setup, because the setup-only assertion passes against the broken form.

`isFlipped` supplies the Y flip; `setBoundsSize` cannot express one. Use absolute `bounds` assignment, never `scaleUnitSquare(to:)`.

`canvas.convert(event.locationInWindow, from: nil)` yields source pixels directly, clipped to `pixelSize`. With `w` in `RegionSelectionView`-local (unflipped) space:

```
px.x = (w.x - D.minX) * pixelSize.width  / D.width
px.y = (D.maxY - w.y) * pixelSize.height / D.height
```

Zoom cannot corrupt stored geometry, reach the exporter, or reach `pendingQuartzRect`, because no code path carries `D` into them.

### Stage scale is per-axis

```
stageScaleX = D.width  / pixelSize.width      // points per source pixel
stageScaleY = D.height / pixelSize.height
canvasUnits(points, axis) = points / stageScale<axis>
```

Two axes, not one: the viewport carries independent X and Y scales and the spec refuses to assume the captured image has exactly the selection's aspect ratio, so a single scalar is insufficient. Editor-only constants convert per axis through one `ChromeMetrics` struct recomputed on every zoom change. Mark geometry never converts.

### Interpolation, measured correctly

The canvas's local unit is already one source pixel, so device pixels per source pixel is a **direct** conversion of a unit size:

```
let q = canvas.convertToBacking(NSSize(width: 1, height: 1))   // (qx, qy)
```

Passing `stageScale` here instead would yield roughly `backingScale * stageScale²`, because the local unit is a source pixel and not a point. Use `.none` only when **both** `q.width >= 1` and `q.height >= 1`; otherwise `.high`. No claim of exact integer replication is made, since `.bestResolution` guarantees no fixed relationship between selection size and returned image size.

No `wantsLayer` and no `CALayer.contents`: the fly-panel precedent uses `.resizeAspectFill`, which crops on aspect drift. Whether layer-backing disturbs the parent's `.clear` compositing is settled empirically by the spike in Gates, not by any claimed propagation direction.

### Geometry

All math in `RegionSelectionView`-local points, 0-based, because `panel.contentView = regionView` (`:593`) discards the `screenFrame` origin passed at `:579`.

```
S = selectionRect, frozen at annotate-entry
V = screen.visibleFrame.offsetBy(dx: -screenFrame.origin.x, dy: -screenFrame.origin.y)
e = the panel's arrow edge, frozen at annotate-entry
```

| Constant | Value | Source |
|---|---|---|
| `edgePad` | 8 | new |
| `panelReserve` | `8 + panelWidth + 4` = 352 | margin `:618` + `panelWidth` `:51` + clamp inset `:642` |
| `toolbarReserve` | fixed worst-case toolbar **height** + gap + slack | see below |

`toolbarReserve` is a **fixed worst-case constant**, not a measurement. Measuring the live toolbar would be circular: the stepper only appears once `zMax > 1` is known, so adding it could invalidate the allowance that enabled it.

**It is a vertical reserve, corrected during implementation.** The toolbar is a wide horizontal bar and docks *below* the stage, so its footprint is vertical. Reserving its width on the side opposite the panel cost roughly 630pt of horizontal room for something that was never there: measured on device, a 200x80 selection centred at x=600 displayed clamped to x=633, most of the way across the screen from where it was drawn, and wide selections lost a zoom step they could have had.

`panelReserve` derives from one exported constant; 340 already lives in **four** places that must agree (`CommentInputWindowController.swift:51`, `:122`, `:704`, `CommentInputView.swift:107`).

Allowance box `A` (`.leading` = panel right, `.trailing` = panel left, `CommentInputWindowController.swift:624-636`), toolbar docked opposite:

| `e` | `A` |
|---|---|
| `.leading` | x in `[V.minX + edgePad, V.maxX - panelReserve]`, y in `[V.minY + edgePad + toolbarReserve, V.maxY - edgePad]` |
| `.trailing` | x in `[V.minX + panelReserve, V.maxX - edgePad]`, same y |
| `.top`, `.bottom`, `nil` | magnification disabled, `z = 1` |

`displayRect` returns **both** the rect and the zoom it actually achieved:

```
func displayRect(S, requested z, pixelSize, A, backing) -> (effectiveZoom: Int, rect: CGRect)

guard z > 1 else { return (1, S) }              // z == 1 is byte-identical to today

raw = S scaled by z about S's center

// Backing-aligned permitted origin interval, aligned INWARD before clamping.
loX = alignUp(A.minX);  hiX = alignDown(A.maxX - raw.width)
loY = alignUp(A.minY);  hiY = alignDown(A.maxY - raw.height)

guard loX <= hiX && loY <= hiY else { return displayRect(S, z - 1, ...) }   // reduce and retry

return (z, CGRect(origin: clamped-and-aligned origin, size: raw.size))
```

The recursion terminates at `z == 1`, which returns unconditionally. **Every consumer publishes `effectiveZoom`, never the requested value**: the stepper readout, the size-label suffix, the keyboard enable/disable state, and `ChromeMetrics` all read it. Without that, a requested 2x could display `S` while reporting 2x and assuming fitted-rect invariants.

Invariants, scoped to `effectiveZoom > 1`:

| Invariant | Consequence |
|---|---|
| `D` fits inside `A` after inward alignment | the clamp is a translation; the whole image is on screen; **panning is structurally unnecessary** |
| `D` inside `A` inside `V` | midpoint screen lookups (`:650-654`, `:846`) cannot drift to another display |
| `D.midY == S.midY` **to within one device pixel** when the vertical clamp is inactive | the image grows about its center and the panel translates outward by about `(D.width - S.width) / 2`. Exact equality is impossible: backing-aligning the origin quantizes a center `S` itself need not have had on the grid. Tests assert a one-device-pixel tolerance, not equality. |
| `D.width / S.width == effectiveZoom` | exact, because alignment moves only the origin and never the size; asserted in tests |

At `effectiveZoom == 1`, `D == S` and no fit into `A` is claimed: `S` is a rect the user drew on this screen. The panel keeps its placement. The **toolbar has no proven room at 1x**, so it uses an independent fallback chain: preferred opposite edge, then the edge with the most room, then a compact layout clamped inside the overlay. This also covers `Cmd+0`.

### Trigger and limits

```
zHard  = 8
zFit   = min(A.width / S.width, A.height / S.height)
zCeil  = max(1, min(Int(floor(zFit)), zHard))     // 1 is the inert sentinel, not a fit claim
zMax   = largest z in 1...zCeil whose displayRect returns effectiveZoom == z
zAuto  = clamp(Int(ceil(320 / min(S.width, S.height))), 1, zMax)
```

**`zMax` is alignment-aware, not `floor(zFit)` directly.** `zFit` ignores backing alignment, but `displayRect` recurses downward whenever the aligned origin interval is empty, so the largest *achievable* zoom can be `zCeil - 1`. Publishing the unaligned value would leave `Cmd+=` and the `+` button permanently enabled and permanently inert at that boundary: the user presses, nothing happens, forever. So `zMax` is resolved by walking down from `zCeil` to the first level that actually achieves itself, and every published control state reads that resolved value.

| Selection | `zAuto` | Displayed | Behavior |
|---|---|---|---|
| 200 x 80 | 4 | 800 x 320 | the motivating case |
| 40 x 40 | 8 (capped by `zHard`) | 320 x 320 | favicon |
| 400 x 300 | 2 | 800 x 600 | mild help |
| 900 x 600 | 1 | unchanged | inert, byte-identical to today |
| 1200 x 30 | 1 | unchanged | known v1 gap |

Auto-magnification fires simultaneously with the mode transition, so there is no stable "before" frame it contradicts; the entry animation reads as physical enlargement; the size label carries a permanent zoom suffix; `Cmd+0` reverses it. Setting the comfort constant to 0 demotes it to manual-only.

### Comment-panel anchoring

`screenshotSelectionRect` keeps the true capture rect. New controller state:

```
private var annotationActive = false             // the annotation lock, for the whole session
private var displayRectScreen: CGRect?           // SCREEN-GLOBAL AppKit; set whenever annotationActive, including 1x
private var panelAnchorRect: CGRect? { displayRectScreen ?? screenshotSelectionRect }
private var frozenArrowEdge: Edge?               // snapshotted; arrowEdge is nilled elsewhere
```

**The two coordinate spaces are named apart, and the conversion happens exactly once.** All stage math produces `displayRectLocal`, in `RegionSelectionView`-local 0-based points. Everything the controller consumes is screen-global: `repositionForScreenshot` resolves the display with `NSScreen.screens.first(where: { $0.frame.contains(midpoint) })` (`CommentInputWindowController.swift:648-654`), and the existing code adds `screenFrame.origin` before handing selection geometry over (`ScreenCaptureService.swift:663-675`, `:684`, `:691`). Feeding a local rect to those APIs puts the comment panel, the VEV arrow, and the fly frame on the wrong display whenever the overlay is not on the primary screen, including any layout with a negative-X or above-primary display. So `displayRectScreen = displayRectLocal.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)` is computed once in `setZoom`, and only the screen-global value ever crosses into the controller or the toolbar panel.

`annotationActive`, not the nullity of the display rect, is what `repositionForScreenshot` tests, since every zoom including 1x publishes a rect.

The dock/flip/clamp math moves into `AnnotationPanelGeometry` as a pure function taking an optional forced edge. `screenshotPanelOrigin` becomes a thin private caller so the Chrome element-grab path (`:758`) stays byte-identical and the math becomes testable without exposing a private method.

| Site | Currently reads | Change to |
|---|---|---|
| `updatePanelHeight` side-dock recenter `:840-844` | `screenshotSelectionRect` | `panelAnchorRect` (fires on every keystroke) |
| `updatePanelHeight` screen lookup `:846` | `screenshotSelectionRect` | `panelAnchorRect` |
| `updateVEVMask` arrow fraction `:927-941` | `screenshotSelectionRect` | `panelAnchorRect` |
| `saveComment` local snapshot `:291` | one local | **split in two** |
| `requestRegionContext` `:300-308` | the `:291` local | **`screenshotSelectionRect`** - a magnified rect would silently attach DOM context for elements the user never selected |
| fly panel frames `:416`, `:452`, `:457-462` | the `:291` local | **`panelAnchorRect`** |

`setAnnotationDisplayRect(_ screenRect: CGRect?)` takes a **screen-global** rect, sets it, re-runs the panel geometry with the frozen edge, sets the origin, and rebuilds the VEV mask unconditionally. The arrow fraction does not necessarily change under centered growth (unclamped it is 0.5 before and after) but **may** change near clamps, which is why the rebuild is unconditional.

For a side dock with the clamp inactive: gap exactly 8; arrow tip at `D.maxX + 8` with the body 15pt out because `tooltipCGPath` insets by `arrowDepth = 7` (`:971-1012`); fraction 0.5; `D.midY == S.midY` to within one device pixel. Near screen top or bottom the vertical clamp shifts `D` and both the origin clamp (`:643`) and the fraction clamp engage; the gap survives, the centred fraction does not.

### Control surface

| Keys | Action | Gate |
|---|---|---|
| `Cmd+=` / `Cmd+-` | step effective zoom | session active, `zMax > 1`, transaction idle |
| (matching) | **on virtual key code, not characters** | `charactersIgnoringModifiers` ignores every modifier *except* Shift, so `Shift+Cmd+0` arrives as `)` and never matches `"0"`. Measured: the binding was silently inert. |
| `Cmd+0` | `z = 1` | same |
| `Shift+Cmd+0` | `z = zMax` | same |
| bare `+` / `-` | not bound | must keep typing into the comment field |

macOS/Snagit convention, not Shottr's inverted mapping. A `[-] 4x [+]` stepper appears only when `zMax > 1`, cloned from the existing header-button recipe (`ScreenshotPreviewController.swift:175-215`) with both hover **and** pressed states.

### Interaction rules

**Size indicator.** Text is always the true capture size with `" · \(effectiveZoom)x"` appended when above 1. Position, flip test, and clamp derive from `D`.

**Cursor and redisplay.** Every zoom change invalidates cursor rects on both views and sets `needsDisplay` on **both** the canvas and the parent; a frame change marks neither dirty on its own and `ChromeMetrics` has changed.

**Pan.** Does not exist; not needed for fitted zoom.

**Undo.** Zoom is viewport state, excluded.

**Animation.** Entry animates the canvas frame from `S` to `D` over 0.18s ease-out; exit mirrors at 0.14s with teardown in the completion handler. **Canvas input and editor chrome are disabled for the duration of either animation**, because intermediate frames traverse fractional scales where `ChromeMetrics` does not hold. Manual steps are instant. The comment panel moves to its final origin once rather than animating.

**Sequencing.** The overlay and the comment panel are separate `NSPanel`s (`ScreenCaptureService.swift:566`, `CommentInputWindowController.swift:703`), so **no cross-window atomic presentation is claimed**; both update in the same runloop turn and a one-frame skew is accepted and manually verified.

`viewDidChangeBackingProperties()` recomputes the interpolation measurement and re-aligns `D`'s origin, then republishes `(effectiveZoom, rect)` together. `canvas.bounds` and the viewport are backing-independent.

## Durable persistence

`createComment` proves nothing about disk on either branch (`PersistenceManager.swift:296-341`, `:538-564`, `:570-572`). Add a sibling that returns a `Result` and goes through the **same** cross-process protocol as `saveToDisk`:

```
func createCommentDurably(...) async -> Result<Comment, PersistenceError>
```

It is `async`: the lock wait cannot run on the main actor (below), so the entry point awaits an off-main helper. Cancellation is **not** honored once the helper has entered the lock; a cancelled task still completes the write and publish, because abandoning between rename and publish would strand the document. Callers cancel before prepare, not during.

**All document writes are serialized, and the serialization must not be re-entrant by accident.** `PersistenceManager` is `@MainActor` (`PersistenceManager.swift:5-6`), but `await` yields the main actor, so a durable write, a debounced `saveToDisk`, and a `reloadFromDisk` adoption (`:76`, `:86`, `:579`) can interleave: the continuation would publish a merged state computed from a snapshot taken before a newer local mutation, clobbering it and regressing the baseline set at `:598`. So durable writes, ordinary saves, and reload adoption all pass through **one serial persistence operation queue**.

A naive queue deadlocks immediately on the existing code. `reloadFromDisk` calls `saveToDisk()` as its **first statement** (`:583`, flushing pending edits before adopting disk state) and then reinstalls a debounce sink that calls `saveToDisk()` again (`:585-589`). If both `reloadFromDisk` and `saveToDisk` are queued operations, the first external write self-deadlocks: a queued operation waits on the queue it already owns.

So the layering is explicit, and the split is the design, not an implementation detail:

- **`performDocumentWrite(...)`** is the unqueued primitive. It assumes the caller already owns the serialized slot, and performs exactly one lock-held read, merge, encode, and atomic rename. It never enqueues.
- **Every public entry point** (`saveNow`, `saveImmediately`, the debounce sink, `createCommentDurably`) enqueues one slot and calls the primitive once inside it.

  Two of those entry points are synchronous today and cannot simply become fire-and-forget. `saveNow()` exists so the wake payload is on disk before the hooks event fires (`PersistenceManager.swift:330-336`), and `quitApp` calls `saveImmediately()` and then `NSApp.terminate(nil)` on the very next line (`AppController.swift:522-525`). Returning immediately from either loses the write; blocking the main actor while an earlier slot still needs its main-actor publish step deadlocks. So wake creation becomes `async` all the way to its callers, and termination defers via `applicationShouldTerminate` returning `.terminateLater`, with `reply(toApplicationShouldTerminate:)` sent once the queue has drained and published.

Two prerequisites, because neither exists today: Remarc implements no `applicationShouldTerminate` at all, so the delegate method must be added; and `NSSupportsSuddenTermination` must be set to `false` in Remarc's `Info.plist`, or macOS may terminate the process without calling the delegate and the deferral never runs. Shipping the async queue without both would make quit *less* durable than the synchronous `saveImmediately()` it replaces.

The queue contract states debounce, wake, and shutdown behavior explicitly rather than leaving them to the implementation.
- **`reloadFromDisk` is one queued operation, not two.** Inside a single slot it performs the flush write and the adoption together by calling the primitive directly, rather than re-entering through `saveToDisk`.

Anything reached from inside a slot uses the primitive; only outside callers enqueue. A debug assertion that the primitive is never entered without owning the slot keeps a future caller from reintroducing the nesting.

Only one document operation is ever in flight; the others wait.

On completion the entry point does not blindly assign. It rebases, and **the base must be named explicitly** because getting it wrong deletes the comment that was just written:

```
launchState = appState            // snapshotted BEFORE candidate is built
committed   = <state the helper wrote>
appState    = AppStateMerge.merge(base: launchState, ours: appState, theirs: committed)
```

`launchState` is the pre-candidate snapshot, not `candidate`. If `candidate` were the base, the durably written comment would be present in both base and theirs but absent from the current `appState`, and `mergeEntities` appends an entity from `theirs` only when it is absent from base (`AppStateMerge.swift:121-126`). The comment would be dropped from memory and the next ordinary save would delete it from disk.

The returned state becomes `lastPersisted`, any remaining local delta is scheduled as an ordinary save, queued reloads are processed, and only then is the webhook dispatched.

**The webhook guarantee is narrow and stated as such.** This design promises exactly one in-process `dispatch()` call after publication, and nothing more. It is not end-to-end exactly-once delivery: `WebhookService.dispatch` is fire-and-forget and each delivery makes up to three attempts (`WebhookService.swift:23-24`, `:40-49`, `:118-159`), so an ambiguous response can arrive twice at the receiver, and a crash between the atomic rename and the dispatch loses the event entirely. Achieving real exactly-once needs an outbox persisted atomically with the document plus receiver-side idempotency, which is data-layer scope and out of scope here. Because `dispatch` is also called from the reload diff (`WebhookService.swift:41-42`), the queued-reload step must suppress the event for a comment this transaction just created, or the same creation fires twice.

**The target session is pinned for the duration.** Validating it inside the helper only compares `candidate` against `onDisk`; it cannot see a local deletion that lands during the await. `deleteSession` mutates `appState` synchronously (`PersistenceManager.swift:161-172`, which also soft-deletes every comment in the session) and the inactivity timer can call it unattended (`:696-710`). Without a pin, the rebase re-applies that deletion after validation succeeded, reproducing exactly the invisible-comment state validation exists to prevent. So a durable create pins its target session id: `deleteSession` for a pinned id is deferred until the transaction terminates, then applied.

The sequence:

1. Build `candidate`: a copy of `appState` with the auto-created session (if needed), the new comment, **and the `totalCommentsCreated` increment already applied**. Do not touch `appState`, `lastPersisted`, or dispatch anything yet. The counter must be inside the candidate because it is part of the encoded `AppState` (property `AppState.swift:7`, encoded at `:74`) and the merge resolves it by `max` (`AppStateMerge.swift:48-51`); incrementing after the write would diverge memory from disk.
2. Validate the target session (below), then hand `candidate` and `lastPersisted` to a `nonisolated` helper that performs acquire, re-read, merge, encode, and atomic rename **off the main actor**, returning the merged state or throwing.
3. Inside the helper, `DocumentLock.withLock(fileURL)` (`DocumentLock.swift:26-31`): read the file and **propagate any read or decode error without writing**. Falling back to `lastPersisted` on an undecodable document, as `saveToDisk` does (`PersistenceManager.swift:541-547`), would overwrite a malformed, briefly unreadable, or forward-incompatible file with stale state and destroy whatever a newer build wrote. The only permitted fallback is an explicitly detected missing-file bootstrap. Then `AppStateMerge.merge(base: lastPersisted, ours: candidate, theirs: onDisk)`, encode, atomic write.
4. Back on the main actor: rebase as described, publish, dispatch the webhook once, and return `.success` with the comment looked up by ID in the merged state.
5. On `DocumentLock.TimedOut`, a read/decode error, or any encode/write error, return `.failure` having mutated nothing observable and dispatched nothing.

Because the write completes inside the lock before returning, the wake ordering requirement that `saveNow()` exists for (`PersistenceManager.swift:330-336`) is satisfied by construction; the wake path needs no extra save.

`DocumentLock.acquire` polls with `Thread.sleep(forTimeInterval:)` up to a 2s timeout (`DocumentLock.swift:33-54`, sleep `:51`, timeout `:15`), which is why the wait must be off-main: this design puts it on the capture save's critical path during the fly animation. `AppState` and its members are value types, so the candidate crosses the boundary by copy.

### Session validation

A fresh comment survives the merge unconditionally: in `mergeEntities`, an entity present in `ours` but absent from `base` takes the "we created it" branch (`AppStateMerge.swift:100-103`), and because its ID is absent from `base`, `mergeComment` is never called and the candidate is appended unchanged. Looking it up by ID afterwards is therefore guaranteed to succeed.

Its **session** is not so protected. Sessions merge as whole entities (`AppStateMerge.swift:30-33`), so if another writer soft-deletes the target session after staging, "theirs" wins for that untouched session while the new comment keeps pointing at it. Deleted sessions are excluded from navigation (`PersistenceManager.swift:125`), so the comment would exist but be invisible.

So before encoding, the helper checks the prospective merge: if the comment's target session is absent or `isDeleted`, it **fails with a conflict** rather than writing. The transaction restores, the capture stays alive with its draft and annotations intact, and the user is told the session went away. V1 does not silently reparent to Inbox; that would move a comment somewhere the user did not choose.

### Prepared-capture leases, not a directory sweep

An "unreferenced image" sweep would delete files Remarc deliberately retains: expired comments are pruned while their images move to `appState.orphanedImages` and survive until the image-retention cutoff (`PersistenceManager.swift:776-789`, `:794-802`), and attachments are written before any comment references them and can stay draft-held (`CommentInputView.swift:39`, `:336`).

So reconciliation never enumerates the images directory. Instead:

- The registry is a single file, `Remarc/images/.prepared-leases.json`, and every read-modify-write of it is performed under `DocumentLock.withLock(leaseRegistryURL)`. `DocumentLock` is keyed by the URL it is handed (`DocumentLock.swift:21-23`), so naming the target explicitly is what makes the operation atomic across instances; "written under DocumentLock" without a named target guarantees nothing.
- Before writing a prepared PNG, record `{path, pid, bootTime, startTime, at}`.
- `finalize` and `restore` each remove the entry; exactly one owner is responsible for the file.

**Owner identity is PID plus process-start identity, and age alone never reclaims.** A bare PID is reusable and a timestamp cutoff can elapse while a process is merely suspended or slow, so the round-4 hazard is real: another instance reclaims a live transaction's PNG, sees no comment referencing it, deletes it, and the original process then durably creates a comment pointing at a missing file. `DocumentLock`'s own reclaim treats age independently of liveness (`DocumentLock.swift:65`), which is tolerable for a lock and not for a file that a comment will reference.

So at startup a lease is reclaimed **only** when its owner is confirmed gone: the PID is dead by the `kill(pid, 0) != 0 && errno == ESRCH` test (`DocumentLock.swift:58-78`), **or** the PID is live but its recorded boot time and process start time do not match the running process, meaning the PID was recycled. A confirmed-live owner is never reclaimed regardless of age. Even then the file is deleted only when no comment (including soft-deleted ones), no attachment, and no `orphanedImages` entry references it.

Ordering matters on the failure path: `restore` deletes the PNG **before** removing the lease, and retains the lease if deletion fails, so a file that could not be removed stays owned and reclaimable rather than becoming an untracked orphan.

Every decoded lease path is **containment-validated before deletion**, not trusted. `resolveImagePath` appends whatever relative components it is given (`Constants.swift:36-39`), so a corrupted or hand-edited registry could otherwise aim a delete anywhere. A path is deleted only if it resolves to a canonical strict descendant of `Remarc/images` and matches the generated UUID-PNG filename shape.

Files outside the registry are never touched. The existing retention pass keeps sole ownership of `orphanedImages`.

## Capture save transaction

### State machine

`CommentInputController` holds one `captureTransaction`: `.idle`, `.preparing`, `.animating`, `.creating`, `.concluding`. Save, wake-save, dismissal, annotate entry/exit, and zoom are refused unless `.idle`.

The happy path is `idle -> preparing -> animating -> creating -> concluding -> idle`, but it is not the only path, and several failures occur **before a token exists**:

| From | Trigger | To | Resource handling |
|---|---|---|---|
| `.idle` | save or wake-save with the gate open | `.preparing` | none yet |
| `.preparing` | inline-edit commit fails, generation wait fails, capture fails, encode fails, lease creation fails, or PNG write fails | `.concluding` | conclude with whatever partial resource exists: no file, a lease with no file, or a file with a lease |
| `.preparing` | success | `.animating` | token now owns file + lease |
| `.animating` | animation interrupted, window closed, or app deactivates | `.creating` | the animation is cosmetic; never abort the save because of it |
| `.animating` | completes | `.creating` | unchanged |
| `.creating` | durable success | `.concluding` (finalize) | clipboard, then lease removal |
| `.creating` | durable failure or session conflict | `.concluding` (restore) | delete PNG, then remove lease |
| `.concluding` | always | `.idle` | unconditional |

`concludeTransaction(_ outcome:)` is **nonthrowing and exactly-once**, takes an optional partial prepared resource, and always lands in `.idle`. Cleanup failures inside it never re-enter it:

- After durable success, a failed lease removal does **not** trigger restore. The comment is on disk and the file is referenced; a stale lease entry is harmless and the next startup sweep will find the file referenced and drop the entry.
- During restore, a failed PNG deletion retains the lease so the file stays owned, as described above.

A stale token passed to `finalize` or `restore` returns an observable `.staleToken` outcome rather than silently doing nothing, so a stranded prepared file cannot leak unnoticed.

Entry is guarded in **two** places, because both real call sites reach the service directly (`GlobalHotkey.swift:222`, `PopoverContentView.swift:250`): both route through one gated controller API, and `ScreenCaptureService.startCapture` itself rejects re-entry while a capture or transaction is live rather than overwriting callbacks and pending state (`ScreenCaptureService.swift:526-551`).

### Prepare

1. `commitActiveEditForOutput()`; abort with an error if a pending label cannot be committed.
2. Await the latest committed composite generation.
3. Choose the base: the frozen `CGImage` when a session exists, otherwise the existing deferred below-overlay grab.
4. Encode PNG, record the lease, and atomically write a new UUID path under `Remarc/images`, while the overlay, comment draft, controller fields, and session stay intact.
5. Return `PreparedCapture(token, relativePath, cgImage, pointSize)`. On any error mutate no pending state, leave every editor usable, and report to Sentry as `commitCapture` does today (`ScreenCaptureService.swift:733-735`).

### Animate, create, conclude

1. Build a retained `CaptureSaveDraft`: comment text, attachments, target session, source bundle ID, **`wakeRequested`** (`CommentInputWindowController.swift:275`), web-context intent, annotation session, magnification state, and the frames, alpha, visibility, and key responder of the comment panel, overlay, and toolbar. Clear nothing.
2. Order out the toolbar and run the existing choreography, building the fly panel from `PreparedCapture.cgImage` with `contentsGravity = .resize`, starting from `panelAnchorRect`. Remove the independent `.optionOnScreenOnly` grab (`:435-440`).
3. Where `commitScreenshot()` runs today, consume pending web context and region elements, store them in the draft, **and publish them to controller state** so the badge (`CommentInputView.swift:212`) and any retry can read them.
4. `AppController.prepareBadgeBounce()`, then `createCommentDurably`.
5. On `.success`, copy to the clipboard if the preference is on (preserving `ScreenCaptureService.swift:722-724`, now gated on durable success), then conclude with finalize. **The caller never touches the lease**: `finalize` and `restore` are the only lease owners, and exactly one of them runs. Finalize dismisses the overlay, releases frozen and render state, removes the lease, clears controller and draft fields, animates the badge, and returns to `.idle`.
6. On `.failure`, conclude with restore: delete the prepared PNG and its lease, cancel the prepared badge without animating (add `cancelPreparedBadgeBounce()` beside `prepareBadgeBounce`, `AppController.swift:172-176`), restore panel frames, alpha, visibility, canvas focus, and magnification, **reinstall the height observer and the click-outside monitor removed at `CommentInputWindowController.swift:351-353`**, keep retained web context available, show the local error, and return to `.idle`.

Both scheduling branches (`:471`, `:476`) run this identical sequence; only the presence of a fly panel differs.

The saved PNG is untouched by magnification: the capture excludes everything at or above the overlay's `windowNumber`, and the canvas is a subview.

## Preview-panel flow

1. Add **Annotate** to the existing header.
2. Replace the SwiftUI `Image` with `AnnotationCanvasRepresentable` framed to the exact aspect-fit rect. **No `GeometryReader` exists in this file** and `imageDisplaySize` (`ScreenshotPreviewController.swift:150-169`) is dead code with wrong constants; compute the rect fresh, accounting for the outermost `.padding(.horizontal, 16)` (`:237`) subtracting 32pt before the flexible frame expands, plus letterbox centering.
3. Keep the toolbar inline; a second panel would fight the single-panel `ClickOutsideMonitor`. Its `shouldDismiss` veto (`PanelHelpers.swift:16`) suppresses dismissal during an inline edit. The veto is used elsewhere (`MenuBarPopoverController.swift:84`, `FloatingEditorController.swift:323`, `CommentInputWindowController.swift:902`); it is unused only at the preview's own install site, which takes the `{ true }` default (`ScreenshotPreviewController.swift:97`).
4. Route **every** dismissal through one `requestDismiss(intent:)`, with the same one-layer-per-invocation rule. Escape alone is not enough: `show()` calls `dismiss()` as its first statement (`ScreenshotPreviewController.swift:22-23`), so opening a second preview silently destroys a dirty session, and both the close button and the click-outside callback call `dismiss()` directly (`:97`). The paths that must route through it are panel Escape, canvas Escape, inline-text Escape, the close button, click-outside, app deactivation, and a replacement `show()`, which queues its new image until the current session's discard is resolved.

   `ClickOutsideMonitor` installs a **global** monitor only (`PanelHelpers.swift:16-27`), and a global monitor does not observe events delivered to the installing app, so clicks on Remarc's own other windows never reach it. Covering both requires a local monitor alongside the global one, or a local monitor plus resign-active handling.
5. Copy calls `commitActiveEditForOutput()` then copies the committed composite when annotation is active, otherwise the source image.
6. Rename the download action to **Save As...**. Cancellation or write failure restores the panel and session instead of the current unconditional `dismiss()` at `:121`.
7. Add **Apply annotations**, enabled only when dirty. Resolve both the candidate URL and `remarcAppSupportURL/images` with `standardizedFileURL.resolvingSymlinksInPath()` and compare path components to require strict descendancy, then render, encode, and atomically replace.
8. On success, start a fresh session generation from the composite, leave the panel in non-annotation mode, and bump the path revision.

All four entry points must call `ScreenshotPreviewController.shared.show(imagePath:commentText:)`, including the new `HistoryCardView` tap action.

Zoom in the preview panel is out of scope for v1.

## Thumbnail refresh

`StoredImageRevisionCenter.shared` holds monotonically increasing revisions keyed by relative path. `ScreenshotThumbnailView` observes it and reloads bytes with `Data(contentsOf:)` then `NSImage(data:)` rather than the lazy `NSImage(contentsOf:)`. The controller bumps only after a successful atomic replacement. No schema changes.

## Error presentation and cleanup

- Freeze, prepare, durable creation, preview apply, and Save As return typed errors; no `try?` for user-initiated writes.
- Mount `ToastOverlay` in both `AnnotationToolbarView` and `ScreenshotPreviewView`, reading `ToastManager.shared.currentToast` inside `body`.
- Teardown releases source images, filter and composite caches, canvas and tool panels, and every monitor: `escapeMonitor` and `globalEscapeMonitor` (`ScreenCaptureService.swift:609-623`), `autoSaveClickMonitor` (`CommentInputWindowController.swift:189-193`), the screenshot-mode key monitor, and the preview `ClickOutsideMonitor`.

## Persistence and compatibility

No model or migration changes. `CommentType.screenshot(imagePath:)`, `Comment.attachments`, export, MCP, copy, and share keep consuming the same relative PNG path. Runtime vector state, zoom, and revision counters are not serialized. Atomic preview replacement is allowed only beneath `Remarc/images`.

## Accessibility and visual rules

`remarc*` tokens for chrome, fixed sRGB for exported ink; AppKit VEV owns material with no SwiftUI material over it; every control has a label, tooltip, selected value, focus ring, and at least a 24-point hit target; hover, pressed, selected, disabled, and confirmation states are explicit.

## Framework and source decisions

Core Graphics, Core Image, and AppKit on macOS 14; `CGImageSource` to decode at exact pixel dimensions; Core Image clamp -> filter -> crop cached per immutable source and never keyed by zoom; a source-sized `CGBitmapContext` plus `NSBitmapImageRep(cgImage:)` to encode; AppKit backing conversion in preference to arithmetic on `backingScaleFactor`.

Candidate sources are not vendored here. Before copying, pin an exact upstream commit, verify path and license, and record per adapted file the upstream URL, commit, copyright, license, and changes. BetterShot contains no zoom code at all. Snapzy's zoom lives in a windowed editor and is applied as a SwiftUI `.scaleEffect` outside the drawing view, which is why it must reach back into zoom state for tolerances and misses two of four sites; do not copy that structure. The magnification feature is written fresh.

## Verification plan

### Unit tests

- Viewport transforms at several scales, odd pixel sizes, resized preview bounds, flipped origins. **Probe points must be asymmetric.**
- `AnnotationStageGeometry`: allowance box per edge including the disabled sentinel; `zFit`/`zMax` including `floor(zFit) == 0`; `zAuto` for the table above; `displayRect` returning `(1, S)` exactly at `z == 1`, inward-aligned interval bounds, the empty-interval case reducing zoom, and **`effectiveZoom` matching `D.width / S.width` in every case**.
- Effective-zoom publication: stepper readout, label suffix, key enablement, and `ChromeMetrics` all follow the returned value, never the requested one, including after a simulated backing change.
- Interpolation measurement: `convertToBacking(NSSize(width: 1, height: 1))` yields device pixels per source pixel, and a `stageScale`-sized input would not; `.none` requires both axes at or above 1.
- `AnnotationPanelGeometry`: byte-identical output to the current three-test-plus-fallback chain and clamp with no forced edge; forced-edge origin and a 0.5 arrow fraction.
- Canvas transform: `convert` matches the closed form at several zooms; the viewport is bit-identical across zoom and backing changes.
- Compositor: the canvas raster and the exported raster are the same object; a golden-image test at several stage scales; the transient raster survives until a newer committed generation lands; export awaits the latest generation; a full 5K committed render meets the stated budget.
- Global z-order: interleaved filter and vector items render in list order, and filters still sample the immutable base.
- `createCommentDurably`: a write failure and a lock timeout each publish no state, dispatch no webhook, and return an error; success publishes exactly once and returns the merged comment; a concurrent external edit made between read and write survives the merge.
- Lease reconciliation: retained `orphanedImages` entries, draft attachments, in-flight prepared captures owned by a live pid, and crash leftovers from a dead pid are each handled correctly, and the images directory is never enumerated.
- Transaction: re-entrant save and a second `startCapture` are both refused; every error path reaches `concludeTransaction` and returns to `.idle`; `finalize` and `restore` are idempotent and a stale token is observable.
- Fault injection across both scheduling branches, for ordinary Save **and** Wake Save: capture, render, encode, write, and durable-creation failures restore draft, session, magnification, web context, height observer, and click-outside monitor.
- Owned-path validation, atomic preview replacement, and a revision bump reloading only the edited path.

### Interaction and manual verification

- Text-editor keys stay text-editor keys while the comment field is focused; Shift-Command-A enters annotation only once `panelLayoutReady` and the transaction is idle.
- Voice auto-save countdown cancellation still works on the text-selection path.
- One Escape resolves exactly one layer: inline edit, then toolbar focus, then discard controls, then capture.
- Parent selection drawing, resizing, cursor rects, handles, and size label are suppressed while a session exists and resume after exit.
- Magnification: auto-fire on a small region, all four bindings, stepper limits, panel gap and arrow, size label reporting true size with the effective-zoom suffix, near-edge clamping, input locked during animation, toolbar fallback at 1x, inertness for large regions and vertical docks.
- Save and Wake Save with and without annotation and magnification; clipboard honored only after durable success; the fly animation using the exact final image from the displayed rect.
- Preview Apply versus Save As, cancellation restoration, copy of the unsaved composite, all four entry points, immediate thumbnail refresh.
- Multi-display capture and fly behavior; 1x and Retina; a display-mode change mid-session; tiny selections; dark and light rendering; VoiceOver traversal.
- Repeated enter/cancel/show cycles leave no monitors, panels, prepared files, leases, images, or caches alive.
- Drawing latency at 5K with an active gesture, and peak memory with source, filter, committed, and transient rasters resident.

### Build verification

Implement in a dedicated `.worktrees/screenshot-annotation` worktree, then:

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
```

Relaunch after every successful build per CLAUDE.md, and verify the launched path belongs to the worktree.

## Coordination with other in-flight work

Surveyed at `26fa725`. Only two branches are genuinely active; the rest last moved months ago and are stale rather than competing.

### Hard dependencies on unshipped data-layer scope

`docs/superpowers/specs/2026-08-06-data-layer-integrity-design.md` has Swift scope that landed only partly. Verified absent from the source at this baseline: no `unknownFields`, no dirty-entity tracking, no content-hash detection.

| Data-layer item | Shipped? | Effect on this design |
|---|---|---|
| `unknownFields` passthrough bag on `AppState`/`Session`/`Comment` `Codable` | **No** | **Hard dependency.** `createCommentDurably` stages, encodes, and writes a whole `AppState`. Until the bag exists, that write strips any field the current build does not model, exactly the data-loss bug the data-layer spec calls Bug 2. When it lands, `AppStateMerge` must carry the bag too, or the merge reintroduces the loss. |
| Dirty-entity-id tracking with rebase (data-layer spec, Bug 1 fix 2) | **No** - the shipped implementation chose a three-way `AppStateMerge` against `lastPersisted` instead | **Conflict risk.** This design mirrors the shipped merge. If the dirty-id approach is still intended, `createCommentDurably` must be rewritten alongside `saveToDisk`; if it is not, the data-layer spec is stale and should say so. Resolve which before implementing. |
| Content-hash change detection | **No** | Adjacent only; affects `reloadFromDisk`, which this design does not touch. |
| Surface a lock-acquisition timeout as an error rather than swallowing it (Bug 1 fix 5) | **No** - `saveToDisk` still swallows it (`PersistenceManager.swift:556-563`) | **Alignment, not conflict.** This design's `Result` return is the same direction the data-layer spec asks for. Note it as a deliberate first instance rather than a unilateral behavior change. |
| An accurate `totalCommentsCreated` | **No** - the merge resolves it by `max` (`AppStateMerge.swift:48-51`), so two processes creating in the same window both land at `base + 1` | **Pre-existing defect this design surfaces but does not fix.** Preferences presents the value as an exact total (`PreferencesWindowController.swift:2371`), so the label is wrong under contention. Fixing it needs additive three-way deltas in the merge, which is data-layer scope; short of that the label should read as an approximate watermark. Do not mistake an undercount for a durability failure. |

The lock primitive itself is settled and consistent: Swift uses an atomic `mkdir` (`DocumentLock.swift:39-47`) and the live `chore/sync-mcp-data-layer` branch implements the same `mkdir` protocol at the same `.lock` path in `withDocument`. The data-layer spec's text still says `flock`, which is stale against both implementations; do not "correct" `DocumentLock` to match the prose.

### Sequencing against wake-on-comment

`docs/superpowers/specs/2026-08-06-wake-on-comment-design.md` scope item 3 is "Wake screenshot - capture variant ending in the wake action; optional hotkey slot". Most of it **has already shipped**: the shared comment panel renders `WakeButton` whenever the preference is on (`CommentInputView.swift:94-101`), the screenshot panel uses that same view, and the screenshot branch passes the flag straight through (`CommentInputWindowController.swift:334`). Wake-on-screenshot works today. Only the dedicated hotkey slot is outstanding.

That hotkey would add a **third** caller of `ScreenCaptureService.startCapture` alongside `GlobalHotkey.swift:222` and `PopoverContentView.swift:250`, which is why this design puts the re-entry guard inside the service rather than only in a controller wrapper: a controller-only gate would be bypassed by the new hotkey on day one. It is also why `CaptureSaveDraft` must carry `wakeRequested` - the flag is live on the capture path now, not hypothetically.

That spec's item 2, "synchronous save on that path only", is **superseded** here: `createCommentDurably` writes inside the lock for every capture save, so the wake path needs no separate `saveNow()`. Whoever implements Wake screenshot should not add one.

### Floating stack mode

`floating-stack` is an unmerged, docs-only branch adding `2026-08-06-floating-stack-mode-design.md`. It renders real screenshot thumbnails in its cards and vends `public.file-url` for the image. Two integration points, neither a conflict:

- Its thumbnails must observe `StoredImageRevisionCenter`, or a preview Apply will leave stale un-annotated images in the stack.
- Its drag payload references canonical image paths. Prepared-capture leases never rename canonical files and the sweep never enumerates the directory, so a stack card can never be pointed at a reclaimed file.

### Not in conflict

`chore/sync-mcp-data-layer` touches only `mcp/` TypeScript (zero Swift files). The remaining unmerged branches (`figma-support`, `envelope-animation`, `inline-license-success`, `invite-faq`, `codex-invite-page-codex`, and the `codex/*` set) last moved between March and July and diverge from `main` by hundreds of commits; they are abandoned rather than competing, and none should be rebased onto this work.

## Blocking gates before feature code

1. **Freeze-grab fidelity.** The freeze uses `.optionOnScreenBelowWindow(overlayWID)` while the overlay is at full alpha, the first time that path runs outside teardown. If it returns dimmed pixels, WYSIWYG and the exported PNG both break silently. **PASSED on device 2026-08-06** (`spikes/freeze-grab`): a pure-red window under a full-alpha 50%-black `.screenSaver` overlay grabbed as `RGBA = 255, 0, 0, 255`. The grab ignores the overlay entirely. The 400x300pt target returned an 800x600 image, confirming `.bestResolution` follows the backing scale here.
2. **Subview-over-cutout spike.** **PASSED on device 2026-08-06** (`spikes/subview-cutout`), measured against a known pure-red backdrop rather than the desktop, so "transparent" is distinguishable from "dark wallpaper":

   | Question | Measured | Verdict |
   |---|---|---|
   | opaque child over the cleared region | `0,255,0` pure green | the canvas composites opaquely; no parent change needed |
   | cutout transparent with no child | `255,0,0` - the backdrop shows through | `.clear` compositing still works |
   | dim fill outside the cutout, before and after `addSubview` | `128,9,6` both times | adding a subview does not disturb the parent's dim |
   | backing-layer identity across `addSubview` | same `NSViewBackingLayer` pointer, `wantsLayer == false` | unchanged |

   The originally specified assertion `regionView.layer == nil` is **wrong** and was corrected in the constraints table: AppKit backs every in-window view implicitly. Asserting nullity would have failed this gate for a reason that has nothing to do with the design.
3. **Durable persistence, leases, and the transaction machine land before magnification**, since magnification changes what the fly animation shows and the restore paths are otherwise untestable.
4. **Data-layer divergence: RESOLVED 2026-08-06.** Both halves, decided on inspection of the shipped source:

   - **`AppStateMerge` is settled; dirty-entity rebasing is stale.** The three-way merge shipped in `770baa0`, is the only path `saveToDisk` takes, and is covered by `AppStateMergeTests`. `createCommentDurably` mirrors it rather than introducing a second, divergent reconciliation strategy. The data-layer spec's Bug 1 fix 2 describes an approach that was considered and not taken; it should be marked superseded rather than treated as pending work.
   - **`unknownFields` is NOT a hard dependency of this design.** The original framing was wrong. `saveToDisk` already encodes a whole `AppState` and atomically replaces the document on every debounced save (`PersistenceManager.swift:538-564`), so any field the current build does not model is already stripped by ordinary typing in the comment box. `createCommentDurably` writes the same whole document through the same merge and therefore adds **no new exposure**. It is a real pre-existing defect and it belongs to the data-layer spec, not to this one; blocking annotation on it would have been blocking on an unrelated bug that annotation neither causes nor worsens.

5. **Termination durability: prerequisite avoided rather than met.** The spec originally routed every entry point through an async queue, which forced `saveImmediately()` to become async and therefore forced `applicationShouldTerminate` plus `NSSupportsSuddenTermination = false` - machinery Remarc does not have. The implemented design keeps every existing synchronous entry point synchronous and gates them with a single in-flight flag plus deferrals. Ordinary saves cannot interleave with each other because they hold the main actor throughout; only the durable write yields, and only it needs the gate. Quit stays exactly as durable as it is today instead of being made async and then repaired.
6. **Re-verify the persistence citations against `main` at implementation time.** This spec was written while that layer was actively changing; `main` moved twice during authoring.

## Implementation order

1. `createCommentDurably`, prepared-capture leases, startup reconciliation, and the transaction state machine with both entry guards.
2. Document, viewport, stage and panel geometry, renderer, compositor with generations, filters, exporter, revision center.
3. AppKit canvas, representable, toolbar, dismissal coordinator, focus and keyboard routing.
4. Preview integration, Apply versus Save As, History wiring, revision reload.
5. Capture freeze host, parent-behavior gating, panel ladder.
6. Prepare/finalize/restore wiring and the final-image fly choreography.
7. Magnification stage, panel anchoring, zoom control surface.
8. Fault injection, latency and memory budgets, accessibility, multi-display verification, provenance notices, `DESIGN.md` correction.

Both surfaces remain one release unit.

## Known v1 limitations

- Region resize is locked during capture-time annotation; preview Apply is permanent; no crop or spotlight.
- Magnification is unavailable for top and bottom docks, which only occur for selections roughly 800pt or wider, and for long thin strips where the fit zoom floors to 1.
- No panning, no zoom below 1x, no fractional zoom, no pinch or Cmd+scroll; `.magnify` delivery to a nonactivating panel at `.screenSaver` is unverified.
- Exact device-pixel replication is not guaranteed, because `.bestResolution` guarantees no fixed relationship between selection size and returned image size.
- Literal display-pixel parity with the file is not claimed; the shared object is the committed source raster.
- The PNG and the comments JSON cannot be committed atomically together; the lease sweep reclaims a crash-orphaned prepared file.
- A `DocumentLock` timeout makes a save fail rather than silently dropping it, which is a behavior change from the surrounding code and is deliberate.
- No zoom in the preview panel, no loupe annotation object, no capture-time loupe during region drawing, and zoom does not persist across sessions.
- The comfort, pad, and hard-cap constants are unvalidated ergonomic guesses kept in one place.
