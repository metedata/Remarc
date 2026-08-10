import AppKit
import SwiftUI
import UniformTypeIdentifiers

private class KeyablePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            ScreenshotPreviewController.shared.requestDismiss(intent: .escape)
        }
    }
}

@MainActor
public final class ScreenshotPreviewController {
    public static let shared = ScreenshotPreviewController()

    private var panel: NSPanel?
    private let clickOutsideMonitor = ClickOutsideMonitor()

    /// The annotation session for the image on screen, when Annotate is on.
    private var session: AnnotationSession?
    private var currentImagePath: String?
    /// A `show()` that arrived while a dirty session was unresolved.
    private var queuedShow: (imagePath: String, commentText: String?)?

    /// A durable commit is in flight.
    ///
    /// Apply suspends across two renders, and during that window the panel's
    /// controls stayed live: Discard cleared the session while the write was
    /// still going to land, and a replacement `show()` could swap the session
    /// the completion handler was about to tear down.
    private var isApplying = false
    private var localEscapeMonitor: Any?

    public var isAnnotating: Bool { session != nil }

    public func show(imagePath: String, commentText: String?) {
        // A label still being typed is resolved first, exactly as any other
        // dismissal would: committing it is what may make the session dirty, and
        // that has to happen before the gate below, not after. A pending-text
        // session is not dirty, so without this the next line tore it down.
        if let session, session.pendingTextIsActive {
            _ = session.resolveActiveEdit(for: .replacement)
        }

        // `show` used to call `dismiss()` unconditionally as its first statement,
        // so opening a second preview silently destroyed a dirty session. It then
        // queued instead - but routed through `.replacement`, which was exempt
        // from the dirty veto, so the teardown happened anyway. Hold the request
        // and let Apply or Discard release it.
        if session?.isDirty == true || isApplying {
            queuedShow = (imagePath, commentText)
            ToastManager.shared.show("Apply or discard your annotations first.")
            return
        }

        // Nothing is holding a queued request open any more; a stale one would
        // reopen an image the user has moved on from.
        queuedShow = nil
        tearDownPanel()

        guard let nsImage = loadScreenshotImage(imagePath) else {
            debugLog("ScreenshotPreviewController: failed to load image at \(imagePath)")
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        // Constrain to 80% of screen
        let maxWidth = screenFrame.width * 0.8
        let maxHeight = screenFrame.height * 0.8

        let previewView = ScreenshotPreviewView(
            image: nsImage,
            imagePath: imagePath,
            commentText: commentText,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            onDismiss: { [weak self] in self?.requestDismiss(intent: .closeButton) },
            onSave: { [weak self] image in self?.saveImageThroughBarrier(fallback: image) },
            session: nil,
            onToggleAnnotate: { [weak self] in self?.toggleAnnotation() },
            onApply: { [weak self] in self?.applyAnnotations() },
            onDiscard: { [weak self] in self?.discardAnnotations() },
            onCanvasEscape: { [weak self] in self?.requestDismiss(intent: .escape) }
        )

        let panel = KeyablePreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 300, height: 200)

        // NSVisualEffectView as contentView with maskImage
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.maskImage = .roundedRectMask(cornerRadius: AppConstants.panelCornerRadius)
        panel.contentView = visualEffectView

        // NSHostingView as subview of VEV
        let hostingView = NSHostingView(rootView: previewView)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // Measure ideal size first, then size panel to fit
        let fittingSize = hostingView.fittingSize
        let clampedWidth = min(fittingSize.width, maxWidth)
        let clampedHeight = min(fittingSize.height, maxHeight)
        panel.setContentSize(NSSize(width: clampedWidth, height: clampedHeight))

        // Pin with Auto Layout
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        // Center on screen
        let panelX = screenFrame.midX - clampedWidth / 2
        let panelY = screenFrame.midY - clampedHeight / 2
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.currentImagePath = imagePath
        clickOutsideMonitor.install(
            for: panel,
            // The veto exists for exactly this: never dismiss out from under an
            // inline label the user is still typing.
            shouldDismiss: { [weak self] in self?.session?.pendingTextIsActive != true },
            dismiss: { [weak self] in self?.requestDismiss(intent: .clickOutside) })

        // ClickOutsideMonitor installs a GLOBAL monitor only, and a global monitor
        // does not observe events delivered to the installing app, so clicks on
        // Remarc's own other windows never reach it. The local monitor covers that.
        installLocalDismissMonitor(for: panel)
    }

    private func installLocalDismissMonitor(for panel: NSPanel) {
        removeLocalDismissMonitor()
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self, weak panel] event in
            guard let self, let panel, self.panel === panel else { return event }
            if event.window !== panel && self.session?.pendingTextIsActive != true {
                self.requestDismiss(intent: .clickOutside)
            }
            return event
        }
    }

    private func removeLocalDismissMonitor() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
    }

    /// Every dismissal path routes here, and it resolves exactly ONE layer per
    /// invocation: panel Escape, canvas Escape, inline-text Escape, the close
    /// button, click-outside, app deactivation, and a replacement `show()`.
    @discardableResult
    public func requestDismiss(intent: DismissalIntent) -> Bool {
        // A commit is mid-flight. Tearing the panel down now would strand a
        // write that is still going to land.
        if isApplying { return true }

        guard let session else { tearDownPanel(); drainQueuedShow(); return true }

        // 1. An inline label consumes the event.
        if session.pendingTextIsActive {
            session.resolveActiveEdit(for: intent)
            return true
        }
        // 2. A dirty session asks before discarding. No intent is exempt:
        // `.replacement` used to be, which meant opening another preview threw
        // the marks away rather than queueing behind them.
        if session.isDirty {
            ToastManager.shared.show("Apply or discard your annotations first.")
            return true
        }
        tearDownPanel()
        drainQueuedShow()
        return true
    }

    public func dismiss() {
        requestDismiss(intent: .closeButton)
    }

    private func tearDownPanel() {
        session?.teardown()
        session = nil
        currentImagePath = nil
        panel?.orderOut(nil)
        panel = nil
        clickOutsideMonitor.remove()
        removeLocalDismissMonitor()
    }

    // MARK: - Annotation

    private func toggleAnnotation() {
        guard let imagePath = currentImagePath else { return }
        if session != nil {
            guard session?.isDirty != true else {
                ToastManager.shared.show("Apply your annotations, or undo them, first.")
                return
            }
            session?.teardown()
            session = nil
            rebuildContent()
            return
        }
        // Saved marks come back as marks, on a base that already has every
        // redaction burnt in. Absent for anything captured before this existed,
        // or never annotated, in which case the flattened PNG is the base and
        // the session starts empty - the behaviour that shipped before.
        if let restored = AnnotationMarkStore.restore(for: imagePath) {
            let session = AnnotationSession(source: restored.base)
            session.adoptRestored(items: restored.items)
            self.session = session
            rebuildContent()
            return
        }

        // Decoded at exact pixel dimensions: NSImage reports points and defers
        // decoding, which is the wrong basis for a source-pixel coordinate system.
        guard let cgImage = AnnotationExporter.decode(relativePath: imagePath) else {
            ToastManager.shared.show("Could not open that image for annotation.")
            return
        }
        session = AnnotationSession(source: cgImage)
        rebuildContent()
    }

    /// What Apply achieved. The two are not the same failure.
    private enum ApplyOutcome {
        case applied
        /// The visible PNG is committed and correct; only re-editability failed.
        case appliedWithoutEditability(Error)
    }

    /// Flatten the annotations into the app-owned PNG.
    private func applyAnnotations() {
        Task { @MainActor in await self.applyAnnotationsAsync() }
    }

    private func applyAnnotationsAsync() async {
        // One apply at a time. The render suspends, and a second press would
        // otherwise start a parallel write to the same path.
        guard !isApplying else { return }
        guard let session, let imagePath = currentImagePath, session.isDirty else { return }

        isApplying = true
        // Pushes the disabled state into the panel: the render below suspends,
        // and Discard during that window used to drop the session out from
        // under a write that was still going to land.
        rebuildContent()

        let outcome: ApplyOutcome
        do {
            outcome = try await session.withAppliedSplit { split -> ApplyOutcome in
                // Containment-validated: both sides resolved through
                // standardizedFileURL and resolvingSymlinksInPath before comparison,
                // so `..` and a symlinked images directory both land on the real
                // path rather than a string that only looks contained.
                let pngData = try AnnotationExporter.pngData(from: split.flattened)
                try AnnotationExporter.replaceOwnedData(pngData, at: imagePath)

                // Past this line the visible image is committed and correct.
                // Everything below only buys re-editability, so its failure is
                // not a failed Apply and must not skip the revision bump - the
                // user would otherwise be told nothing happened while the file
                // on disk had already changed.
                do {
                    if split.editableItems.isEmpty {
                        // Every mark is permanent now. Leaving the old pair
                        // behind would restore marks the user already flattened
                        // and draw them a second time.
                        try AnnotationMarkStore.removeSidecars(for: imagePath)
                    } else {
                        try AnnotationMarkStore.write(base: split.base,
                                                      items: split.editableItems,
                                                      flattenedPNG: pngData,
                                                      for: imagePath)
                    }
                    return .applied
                } catch {
                    return .appliedWithoutEditability(error)
                }
            }
        } catch {
            debugLog("ScreenshotPreviewController: apply failed - \(error)")
            isApplying = false
            rebuildContent()
            ToastManager.shared.show("Could not apply annotations.")
            return
        }

        isApplying = false

        // Bumped only after a successful atomic replacement, so a thumbnail
        // never reloads bytes that were not written.
        StoredImageRevisionCenter.shared.bump(imagePath)

        // Identity, not presence. The render suspends, and by now the panel may
        // hold a different image's session; tearing down `self.session` blindly
        // would destroy that newer one.
        if self.session === session {
            // A fresh generation from the flattened result. Redactions in it are
            // permanent; any vector marks were written to the sidecar above and
            // come back editable on the next Annotate.
            session.adoptFlattened()
            session.teardown()
            self.session = nil
        }
        rebuildContent()

        switch outcome {
        case .applied:
            ToastManager.shared.show("Annotations applied")
        case let .appliedWithoutEditability(error):
            debugLog("ScreenshotPreviewController: sidecar write failed - \(error)")
            ToastManager.shared.show("Applied, but these marks will not be re-editable.")
        }

        drainQueuedShow()
    }

    /// Drop every mark and leave annotation, without touching the stored file.
    private func discardAnnotations() {
        // A commit is already in flight and will land regardless; letting
        // Discard run here would clear the session while that write completes,
        // leaving the user told "discarded" over a file that did change.
        guard !isApplying else { return }
        session?.teardown()
        session = nil
        rebuildContent()
        ToastManager.shared.show("Annotations discarded")
        drainQueuedShow()
    }

    /// Open a preview that was queued behind unresolved annotation work.
    ///
    /// Called only from the paths that genuinely resolve a session - Apply,
    /// Discard, and a clean dismissal. Draining anywhere else is what let a
    /// replacement tear down work the user had not decided about yet.
    private func drainQueuedShow() {
        guard session == nil, let queued = queuedShow else { return }
        queuedShow = nil
        show(imagePath: queued.imagePath, commentText: queued.commentText)
    }

    /// Rebuilds the hosted SwiftUI content in place, preserving the panel.
    private func rebuildContent() {
        guard let panel,
              let vev = panel.contentView as? NSVisualEffectView,
              let hosting = vev.subviews.compactMap({ $0 as? NSHostingView<ScreenshotPreviewView> }).first,
              let imagePath = currentImagePath else { return }
        var view = hosting.rootView
        view.session = session
        view.isApplying = isApplying
        // Reload the BYTES. `image` is a `let` bound once in show(), and Apply
        // rewrites the file underneath it, so without this the panel kept showing
        // the pre-annotation bitmap and Copy copied that stale one too.
        // `NSImage(contentsOf:)` is lazy and caches per URL, hence Data first.
        if let data = try? Data(contentsOf: resolveImagePath(imagePath)),
           let reloaded = NSImage(data: data) {
            view.image = reloaded
        }
        hosting.rootView = view
    }

    // MARK: - Save

    /// Save As has to export what the user SEES. It used to hand the untouched
    /// original straight to the panel, so exporting an annotated preview wrote a
    /// file with none of the marks on it - and it skipped the output barrier, so
    /// even a pending inline label was ignored.
    private func saveImageThroughBarrier(fallback: NSImage) {
        // Gated on the session existing, NOT on `isDirty`. Typing the first
        // label does not make a session dirty - only committing it does - so
        // hitting Save As mid-label exported the untouched original and silently
        // dropped what was being typed. With no marks at all the barrier renders
        // base + nothing, which is the same bytes as the fallback.
        guard let session else {
            saveImage(fallback)
            return
        }
        Task { @MainActor in
            do {
                let composite = try await session.withFrozenComposite { $0 }
                self.saveImage(NSImage(cgImage: composite, size: session.pixelSize))
            } catch {
                debugLog("ScreenshotPreviewController: Save As render failed - \(error)")
                ToastManager.shared.show("Could not render the annotations.")
            }
        }
    }

    private func saveImage(_ image: NSImage) {
        // Both monitors. Removing only the global one left the LOCAL monitor armed,
        // so the first click in the Save sheet dismissed the preview - and the
        // session with it - underneath the sheet.
        clickOutsideMonitor.remove()
        removeLocalDismissMonitor()
        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "screenshot.png"
        savePanel.begin { [weak self] response in
            Task { @MainActor in
                guard let self = self else { return }

                // Cancellation and write failure both RESTORE. The old code
                // dismissed unconditionally before even checking the response, so
                // cancelling Save As destroyed the panel and any session with it.
                guard response == .OK, let url = savePanel.url else {
                    self.restoreAfterSaveSheet()
                    return
                }
                guard let pngData = image.pngData() else {
                    self.restoreAfterSaveSheet()
                    ToastManager.shared.show("Could not encode the image.")
                    return
                }
                do {
                    try pngData.write(to: url, options: .atomic)
                    self.restoreAfterSaveSheet()
                    ToastManager.shared.show("Saved")
                } catch {
                    self.restoreAfterSaveSheet()
                    ToastManager.shared.show("Could not save the image.")
                }
            }
        }
    }

    private func restoreAfterSaveSheet() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        clickOutsideMonitor.install(
            for: panel,
            shouldDismiss: { [weak self] in self?.session?.pendingTextIsActive != true },
            dismiss: { [weak self] in self?.requestDismiss(intent: .clickOutside) })
        installLocalDismissMonitor(for: panel)
    }

    // MARK: - Test seams
    //
    // Synthetic mouse events cannot reach this panel: a CGEvent left-click on the
    // comment card resolves to the card's SwiftUI contextMenu rather than its
    // onTapGesture, so the panel never opens under automation. These let the tests
    // drive the real controller instead of a reimplementation of it.

    var isPanelVisibleForTesting: Bool { panel?.isVisible ?? false }
    var sessionForTesting: AnnotationSession? { session }
    var currentImagePathForTesting: String? { currentImagePath }
    var panelForTesting: NSPanel? { panel }

    /// The live canvas inside the assembled panel, not a fresh one.
    ///
    /// The drag regression lived in how the canvas was hosted, so a synthetic
    /// canvas built in a test could not have caught it.
    var canvasForTesting: AnnotationCanvasNSView? {
        func search(_ view: NSView) -> AnnotationCanvasNSView? {
            if let canvas = view as? AnnotationCanvasNSView { return canvas }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        guard let root = panel?.contentView else { return nil }
        return search(root)
    }

    func toggleAnnotationForTesting() { toggleAnnotation() }
    func discardAnnotationsForTesting() { discardAnnotations() }

    var isApplyingForTesting: Bool { isApplying }

    /// Puts the controller in the state Apply occupies while its two renders
    /// suspend, without performing the write.
    ///
    /// The gating is what is under test - which controls stay live during that
    /// window - and the suspension itself cannot be held open synchronously.
    func beginApplyForTesting() {
        isApplying = true
        rebuildContent()
    }

    func finishApplyForTesting() async {
        isApplying = false
        await applyAnnotationsAsync()
    }

    func applyAnnotationsForTesting() async {
        await applyAnnotationsAsync()
    }

    func forceTeardownForTesting() { tearDownPanel() }

    // MARK: - Mask Image
}

// MARK: - Header resolve controls

/// The trailing header slot while annotation is on.
///
/// Holds the session as an `@ObservedObject` on purpose: the enclosing
/// `ScreenshotPreviewView` keeps it in a plain `var`, so a control gated on
/// `session.isDirty` up there never re-rendered while marks were being drawn.
/// The Apply button spent the whole time it was needed off screen because of it.
private struct AnnotationResolveControls: View {
    @ObservedObject var session: AnnotationSession
    /// Both controls resolve the session, and a commit is already resolving it.
    let isApplying: Bool
    let onApply: () -> Void
    let onDiscard: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDiscardHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if session.isDirty {
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isDiscardHovered
                                         ? Color.remarcError(for: colorScheme)
                                         : .primary.opacity(0.5))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isDiscardHovered
                                      ? Color.remarcError(for: colorScheme).opacity(0.12)
                                      : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .help("Discard these annotations")
                .accessibilityLabel("Discard annotations")
                .onHover { isDiscardHovered = $0 && !isApplying }
                .animation(.easeInOut(duration: 0.15), value: isDiscardHovered)

                AnnotationApplyButton(action: onApply, isEnabled: !isApplying)
            } else {
                // Nothing drawn yet, so there is nothing to resolve and the
                // ordinary close is honest.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isCloseHovered
                                         ? Color.remarcPrimary(for: colorScheme)
                                         : .primary.opacity(0.35))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
                .onHover { isCloseHovered = $0 }
                .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: session.isDirty)
    }
}

// MARK: - Screenshot Preview View

struct ScreenshotPreviewView: View {
    var image: NSImage
    let imagePath: String
    let commentText: String?
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let onDismiss: () -> Void
    let onSave: (NSImage) -> Void

    /// Non-nil while annotation is on. `var` so the controller can swap it in
    /// place without rebuilding the panel.
    var session: AnnotationSession?
    /// A durable commit is in flight, so every control that could resolve or
    /// replace the session is inert until it lands.
    var isApplying = false
    var onToggleAnnotate: () -> Void = {}
    var onApply: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onCanvasEscape: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var isCloseHovered = false
    @State private var isCopyHovered = false
    @State private var isSaveHovered = false
    @State private var isAnnotateHovered = false
    @State private var copySuccess = false

    /// Compute exact image display size, scaling down to fit within constraints
    private var imageDisplaySize: CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 200, height: 150)
        }

        // Reserve space for header (~34pt) + footer (~48pt) + padding
        let targetWidth = maxWidth - 32  // 16pt padding on each side
        let targetHeight = maxHeight - 100

        let widthRatio = targetWidth / imageSize.width
        let heightRatio = targetHeight / imageSize.height
        let scale = min(widthRatio, heightRatio)

        return CGSize(
            width: max(imageSize.width * scale, 200),
            height: max(imageSize.height * scale, 100)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: copy & save (left), close (right)
            HStack(spacing: 4) {
                Button(action: { copyImage() }) {
                    Image(systemName: copySuccess ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12.5))
                        .foregroundStyle(
                            copySuccess
                                ? Color.remarcSuccess(for: colorScheme)
                                : isCopyHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35)
                        )
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copySuccess ? "Copied!" : "Copy Image")
                .onHover { hovering in isCopyHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isCopyHovered)
                .animation(.easeInOut(duration: 0.15), value: copySuccess)

                Button(action: { onSave(image) }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12.5))
                        .foregroundStyle(isSaveHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Save As...")
                .accessibilityLabel("Save As")
                .onHover { hovering in isSaveHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isSaveHovered)

                Button(action: onToggleAnnotate) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 12.5, weight: session != nil ? .semibold : .regular))
                        .foregroundStyle(
                            session != nil
                                ? Color.remarcPrimary(for: colorScheme)
                                : isAnnotateHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35)
                        )
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(session != nil
                                      ? Color.remarcPrimary(for: colorScheme).opacity(0.14)
                                      : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session != nil ? "Stop annotating" : "Annotate")
                .accessibilityLabel("Annotate")
                .accessibilityAddTraits(session != nil ? [.isSelected] : [])
                .onHover { hovering in isAnnotateHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isAnnotateHovered)
                .animation(.easeInOut(duration: 0.15), value: session != nil)

                Spacer()

                // Close and resolve occupy the same trailing slot: with marks on
                // the image, the X is what you would reach for to leave, and it
                // cannot honour that without deciding their fate first. Showing
                // Discard and Apply in its place asks the question instead of
                // refusing the click.
                //
                // The gate has to live INSIDE a view that observes the session.
                // `session` is a plain `var` here, so an `isDirty` test at this
                // level never re-renders while you draw.
                if let session {
                    AnnotationResolveControls(session: session,
                                              isApplying: isApplying,
                                              onApply: onApply,
                                              onDiscard: onDiscard,
                                              onClose: onDismiss)
                } else {
                    Button(action: { onDismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(isCloseHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isCloseHovered = hovering }
                    .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Image — flexible frame so it resizes with the panel
            VStack(spacing: 6) {
                if let session {
                    // Framed to the exact aspect-fit rect. `imageDisplaySize` above
                    // is dead code with the wrong constants; this computes fresh,
                    // accounting for the outermost 16pt horizontal padding removing
                    // 32pt before the flexible frame expands.
                    GeometryReader { proxy in
                        let fitted = AnnotationPreviewLayout.fittedSize(
                            pixelSize: session.pixelSize, available: proxy.size)
                        AnnotationCanvasRepresentable(
                            session: session,
                            onEscape: onCanvasEscape)
                            .frame(width: fitted.width, height: fitted.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                // Outside the Group that used to wrap both: a Group applies its
                // modifiers to EVERY child, so the toolbar was inheriting the
                // image's clip shape and flexible frame.
                if let session {
                    AnnotationToolbarView(session: session, zoomState: nil,
                                          showsDiscardControls: false,
                                          onUndo: { session.undo() },
                                          onRedo: { session.redo() },
                                          onDone: onToggleAnnotate,
                                          onApply: onApply,
                                          // Wired, not defaulted: an unwired trash
                                          // button renders enabled and does nothing.
                                          onRequestDiscard: onDiscard)
                        .fixedSize()
                }
            }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.15)
                                : Color.black.opacity(0.1),
                            lineWidth: 0.5
                        )
                )
                .padding(.horizontal, 16)

            // Comment text — full width, left-justified
            if let text = commentText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - Actions

    /// Copies what the user sees, waiting for the render rather than racing it.
    ///
    /// This used to commit the pending label and then read `session.composite`
    /// in the same breath. Committing only SCHEDULES a render - `add` kicks it
    /// off in its own Task - so the value read back was the composite from
    /// before the label, and before the most recent mark too. The barrier is the
    /// only way to observe a composite that includes them.
    private func copyImage() {
        guard let session else {
            Self.writeToPasteboard(image)
            flashCopySuccess()
            return
        }
        Task { @MainActor in
            do {
                let composite = try await session.withFrozenComposite { $0 }
                Self.writeToPasteboard(NSImage(cgImage: composite, size: session.pixelSize))
            } catch {
                debugLog("ScreenshotPreviewView: copy render failed - \(error)")
                Self.writeToPasteboard(image)
            }
            flashCopySuccess()
        }
    }

    private static func writeToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func flashCopySuccess() {
        copySuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copySuccess = false
        }
    }
}
