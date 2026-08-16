import AppKit
import SwiftUI
import Combine

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Annotation first. The autoSaveCountdownActive branch below is
        // unreachable in screenshot mode (the policy requires isVoiceInvoked, which
        // screenshots set false) but this panel is shared with the voice path, so
        // it stays exactly as it was.
        if CommentInputController.shared.routeDismissalThroughAnnotation(intent: .escape) {
            return
        }
        if CommentInputController.shared.autoSaveCountdownActive {
            CommentInputController.shared.cancelAutoSave()
        } else {
            CommentInputController.shared.dismiss()
        }
    }
}

@MainActor
public final class CommentInputController: NSObject, ObservableObject {
    public static let shared = CommentInputController()

    @Published public var isVisible: Bool = false
    @Published public var currentSelection: TextSelection?
    @Published public var screenshotImagePath: String?
    @Published public var isScreenshotMode: Bool = false
    @Published public var textResetToken = UUID()
    @Published public var currentText: String = ""
    @Published public var currentAttachments: [String] = []
    @Published public var pendingVoiceText: String?
    @Published public var targetSessionID: UUID?
    @Published public var isVoiceInvoked: Bool = false
    @Published public var autoSaveCountdownActive: Bool = false
    @Published public var autoSaveProgress: Double = 0
    @Published public var autoSaveRemainingSeconds: Int = 0
    @Published public private(set) var saveFeedbackTrigger: Int = 0
    @Published public private(set) var validationFeedbackTrigger: Int = 0
    /// Set by the wake screenshot shortcut: this capture's save wakes a
    /// running session, so Save performs the wake and the separate bolt button
    /// would be redundant. Cleared on dismiss.
    @Published public var wakeOnSave: Bool = false
    @Published public var isSaveButtonHovered: Bool = false
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveClickMonitor: Any?

    private var panel: NSPanel?
    private var panelVEV: NSVisualEffectView?
    private var panelHostingView: NSView?
    private let clickOutsideMonitor = ClickOutsideMonitor()
    private var heightCancellable: AnyCancellable?
    private var isAboveSelection: Bool = true
    @Published public var arrowEdge: Edge? = nil
    private var screenshotSelectionRect: CGRect?
    private var screenshotSourceBundleID: String?

    // MARK: - Annotation anchoring
    //
    // Two coordinate spaces, named apart, converted exactly once. All stage math
    // produces a RegionSelectionView-LOCAL rect; everything here is SCREEN-GLOBAL.
    // `repositionForScreenshot` resolves the display by midpoint lookup and the
    // capture path adds `screenFrame.origin` before handing geometry over, so a
    // local rect reaching these APIs would put the panel, the arrow, and the fly
    // frame on the wrong display whenever the overlay is not on the primary
    // screen - including any layout with a negative-X or above-primary display.

    /// The annotation lock, for the whole session.
    private(set) var annotationActive = false
    /// SCREEN-GLOBAL. Set whenever `annotationActive`, including at 1x.
    private var displayRectScreen: CGRect?
    /// Snapshotted at annotate-entry, because `arrowEdge` is nilled elsewhere.
    private var frozenArrowEdge: Edge?

    /// What the panel, the arrow, and the fly frame follow. Never what the capture
    /// rect is: `screenshotSelectionRect` stays the true capture geometry.
    private var panelAnchorRect: CGRect? { displayRectScreen ?? screenshotSelectionRect }

    /// Retained across the transaction so the web-context badge and any retry can
    /// still read what was consumed: consumption clears the singleton.
    private(set) var retainedWebContext: WebContext?
    private(set) var retainedRegionElements: [WebContext]?
    /// The comment panel's frame before the fly shrank it, for restore.
    private var lastPanelFrameBeforeFly: CGRect?

    /// Published once the deferred `updatePanelHeight()` has run. `show()` schedules
    /// height work asynchronously and first-responder work later still, so entering
    /// annotation before this would compute an allowance from a stale panel size.
    @Published public private(set) var panelLayoutReady = false

    /// Fired once, when the deferred height pass first publishes readiness.
    ///
    /// Polling this from a one-shot `DispatchQueue.main.async` does not work: the
    /// height observer defers through the same queue, so the poll wins the race and
    /// reads false forever, leaving the Annotate control permanently disabled.
    var onPanelLayoutReady: (() -> Void)?
    @Published public var pendingElementWebContext: WebContext?
    public var pendingRegionScreenRect: CGRect?
    private let panelWidth: CGFloat = 340
    private let minPanelHeight: CGFloat = 120
    private let maxPanelHeight: CGFloat = 460
    private let screenshotPanelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    public var suppressClickOutside: Bool = false
    private var draftGeneration: UInt64 = 0

    public var currentDraftGeneration: UInt64 { draftGeneration }

    public func isCurrentDraft(_ generation: UInt64) -> Bool {
        DraftGenerationPolicy.accepts(
            capturedGeneration: generation,
            currentGeneration: draftGeneration,
            isVisible: isVisible
        )
    }

    private override init() {
        super.init()
    }

    @discardableResult
    private func beginDraft(
        selection: TextSelection? = nil,
        screenshotImagePath: String? = nil,
        isScreenshotMode: Bool = false,
        screenshotSelectionRect: CGRect? = nil,
        screenshotSourceBundleID: String? = nil,
        elementWebContext: WebContext? = nil,
        targetSessionID: UUID?,
        wakeOnSave: Bool = false
    ) -> UInt64? {
        guard captureTransaction == .idle else {
            debugLog("CommentInputController: New draft refused while capture save is \(captureTransaction)")
            return nil
        }

        cancelAutoSaveCountdown()
        removeScreenshotKeyMonitor()
        if #available(macOS 26, *) {
            VoiceInputService.shared.cancelRecording()
        }
        if pendingElementWebContext != nil {
            WebSocketService.shared.dismissRegionHighlight()
        }
        endAnnotationAnchoring()

        draftGeneration &+= 1
        currentSelection = selection
        self.screenshotImagePath = screenshotImagePath
        self.isScreenshotMode = isScreenshotMode
        self.screenshotSelectionRect = screenshotSelectionRect
        self.screenshotSourceBundleID = screenshotSourceBundleID
        pendingElementWebContext = elementWebContext
        self.targetSessionID = targetSessionID
        self.wakeOnSave = wakeOnSave
        currentText = ""
        currentAttachments = []
        pendingVoiceText = nil
        isVoiceInvoked = false
        isSaveButtonHovered = false
        saveFeedbackTrigger = 0
        validationFeedbackTrigger = 0
        suppressClickOutside = false
        retainedWebContext = nil
        retainedRegionElements = nil
        lastPanelFrameBeforeFly = nil
        textResetToken = UUID()
        return draftGeneration
    }

    private func endDraftState() {
        draftGeneration &+= 1
        wakeOnSave = false
        cancelAutoSaveCountdown()
        removeScreenshotKeyMonitor()
        panelLayoutReady = false
        endAnnotationAnchoring()
        if #available(macOS 26, *) {
            VoiceInputService.shared.cancelRecording()
        }

        isVoiceInvoked = false
        currentSelection = nil
        screenshotImagePath = nil
        isScreenshotMode = false
        currentText = ""
        currentAttachments = []
        pendingVoiceText = nil
        targetSessionID = nil
        arrowEdge = nil
        screenshotSelectionRect = nil
        screenshotSourceBundleID = nil
        saveFeedbackTrigger = 0
        validationFeedbackTrigger = 0
        isSaveButtonHovered = false
        suppressClickOutside = false
        if pendingElementWebContext != nil {
            WebSocketService.shared.dismissRegionHighlight()
        }
        pendingElementWebContext = nil
        pendingRegionScreenRect = nil
    }

    private func triggerSaveFeedback(announcement: String? = nil) {
        saveFeedbackTrigger &+= 1
        guard let announcement else { return }
        validationFeedbackTrigger &+= 1
        makeCommentPanelKey()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Returns the screen-coordinate center of the status item button, or a fallback near the menu bar.
    private func menuBarTargetPoint() -> NSPoint {
        let statusButton = AppController.shared.statusItemButton
        if let button = statusButton, let buttonWindow = button.window {
            let buttonFrame = button.convert(button.bounds, to: nil)
            let screenFrame = buttonWindow.convertToScreen(buttonFrame)
            return NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first!
        return NSPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY + 10)
    }

    /// Temporarily hide panel so system dialogs (NSOpenPanel) appear unobstructed.
    public func orderOutForSystemDialog() {
        panel?.orderOut(nil)
    }

    /// Re-show panel after a system dialog is dismissed.
    public func orderFrontAfterSystemDialog() {
        panel?.makeKeyAndOrderFront(nil)
    }
    private var pendingFadeIn: Bool = false

    public func showForSelection(_ selection: TextSelection) {
        // Dismiss tooltip
        SelectionTooltipWindowController.shared.dismiss()
        guard beginDraft(
            selection: selection,
            targetSessionID: PersistenceManager.shared.appState.activeSessionID
        ) != nil else { return }

        if let bundleID = selection.appBundleID,
           AppConstants.chromiumBundleIDs.contains(bundleID) {
            // Keep the passive selectionContext that the extension sends at
            // selection time. It is the fallback when a native region query
            // misses because the page script is reconnecting or coordinates are
            // slightly off.
            WebSocketService.shared.clearPendingContextIfStale(olderThan: 30)
            WebSocketService.shared.clearPendingRegionElements()
            if let rect = selection.screenRect, rect.width > 0, rect.height > 0 {
                WebSocketService.shared.requestRegionContext(
                    screenX: rect.origin.x,
                    screenY: rect.origin.y,
                    width: rect.width,
                    height: rect.height,
                    purpose: .textSelection
                )
            }
        } else {
            WebSocketService.shared.clearPendingContext()
        }

        // Use screenRect if valid, otherwise use mouse position
        if let rect = selection.screenRect, rect.width > 0, rect.height > 0 {
            show(near: rect)
        } else {
            let mouse = NSEvent.mouseLocation
            show(near: CGRect(x: mouse.x - 170, y: mouse.y + 10, width: 340, height: 20))
        }
    }

    public func showStandaloneNote() {
        SelectionTooltipWindowController.shared.dismiss()
        guard beginDraft(
            targetSessionID: PersistenceManager.shared.appState.activeSessionID
        ) != nil else { return }
        WebSocketService.shared.clearPendingContext()
        show(near: nil)
    }

    public func showForScreenshot(
        imagePath: String? = nil,
        captureRect: CGRect,
        sourceBundleID: String? = nil,
        wakeOnSave: Bool = false
    ) {
        SelectionTooltipWindowController.shared.dismiss()
        guard beginDraft(
            screenshotImagePath: imagePath,
            isScreenshotMode: true,
            screenshotSelectionRect: captureRect,
            screenshotSourceBundleID: sourceBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            targetSessionID: PersistenceManager.shared.appState.activeSessionID,
            wakeOnSave: wakeOnSave
        ) != nil else { return }
        WebSocketService.shared.clearPendingContext()
        if shouldAttachWebContextToCurrentScreenshot {
            WebSocketService.shared.requestRegionContext(
                screenX: captureRect.origin.x,
                screenY: captureRect.origin.y,
                width: captureRect.width,
                height: captureRect.height,
                purpose: .screenshot
            )
        }
        show(near: captureRect)
        installScreenshotKeyMonitor()
    }

    // MARK: - Screenshot-mode keys

    private var screenshotKeyMonitor: Any?

    /// Local monitor so annotation entry and zoom work while the comment text view
    /// is first responder.
    ///
    /// Entry is Shift-Command-A, not a bare letter and not plain Command-A: the
    /// text view is made first responder on show, where unmodified letters type and
    /// Command-A is Select All.
    private func installScreenshotKeyMonitor() {
        removeScreenshotKeyMonitor()
        screenshotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.isScreenshotMode else { return event }
            return self.handleScreenshotKey(event) ? nil : event
        }
    }

    private func removeScreenshotKeyMonitor() {
        if let monitor = screenshotKeyMonitor {
            NSEvent.removeMonitor(monitor)
            screenshotKeyMonitor = nil
        }
    }

    /// US-layout virtual key codes for the zoom bindings.
    ///
    /// Matched on **keyCode, not characters**. `charactersIgnoringModifiers`
    /// ignores every modifier EXCEPT Shift, so Shift-Command-0 arrives as ")" and
    /// never matched "0" - measured on device: the binding was silently inert and
    /// the stage stayed at 1x.
    private enum ZoomKey {
        static let zero: UInt16 = 29
        static let equals: UInt16 = 24
        static let minus: UInt16 = 27
        static let keypadZero: UInt16 = 82
        static let keypadPlus: UInt16 = 69
        static let keypadMinus: UInt16 = 78
    }

    /// Returns true when the event was consumed.
    private func handleScreenshotKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let capture = ScreenCaptureService.shared

        // Every gate is checked here, once, rather than at each call site.
        guard captureTransaction == .idle else { return false }

        // Entry is Shift-Command-A. `A` is safe to match by character because it is
        // unaffected by Shift.
        if shift, event.charactersIgnoringModifiers?.lowercased() == "a" {
            guard panelLayoutReady, capture.canBeginAnnotation else { return true }
            capture.beginAnnotation()
            return true
        }

        guard capture.isAnnotating else { return false }

        switch event.keyCode {
        case ZoomKey.equals, ZoomKey.keypadPlus:
            capture.stepZoom(1); return true
        case ZoomKey.minus, ZoomKey.keypadMinus:
            capture.stepZoom(-1); return true
        case ZoomKey.zero, ZoomKey.keypadZero:
            capture.setZoom(shift ? capture.stageMaximumZoom : 1); return true
        default:
            return false
        }
    }

    /// Routes a dismissal through the annotation coordinator first.
    ///
    /// Returns true when annotation consumed it, so the caller does nothing
    /// further on that keystroke: exactly one layer resolves per invocation.
    func routeDismissalThroughAnnotation(intent: DismissalIntent) -> Bool {
        guard captureTransaction == .idle else { return true }   // refuse mid-save
        guard ScreenCaptureService.shared.isAnnotating else { return false }
        return ScreenCaptureService.shared.resolveDismissal(intent: intent)
    }

    public var shouldAttachWebContextToCurrentScreenshot: Bool {
        ScreenshotWebContextPolicy.allowsWebContext(sourceBundleID: screenshotSourceBundleID)
    }

    public func appendVoiceText(_ text: String, forDraftGeneration generation: UInt64) {
        guard isCurrentDraft(generation) else {
            debugLog("CommentInputController: Discarded transcription for stale draft")
            return
        }
        pendingVoiceText = text
    }

    // MARK: - Auto-Save Voice Notes

    public func startAutoSaveCountdown() {
        guard VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: isVoiceInvoked,
            autoSaveEnabled: SettingsManager.shared.autoSaveVoiceNotes,
            text: currentText
        )
        else { return }

        cancelAutoSaveCountdown()
        autoSaveCountdownActive = true
        autoSaveProgress = 0

        let duration = SettingsManager.shared.autoSaveDelay.duration
        autoSaveRemainingSeconds = Int(ceil(duration))

        // Install click monitor to cancel on any click in the panel
        // (except clicks on the save button, which should save instead)
        autoSaveClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, !self.isSaveButtonHovered else { return event }
            self.cancelAutoSave()
            return event
        }

        let steps = max(1, Int(duration * 60)) // ~60fps
        let interval = duration / Double(steps)
        let start = Date()

        autoSaveTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled else { return }
                let progress = Double(i) / Double(steps)
                self?.autoSaveProgress = progress
                // Update remaining seconds only when the integer value changes
                let elapsed = Date().timeIntervalSince(start)
                let remaining = max(0, Int(ceil(duration - elapsed)))
                if remaining != self?.autoSaveRemainingSeconds {
                    self?.autoSaveRemainingSeconds = remaining
                }
            }
            guard !Task.isCancelled else { return }
            self?.performAutoSave()
        }

        debugLog("CommentInputController: Auto-save countdown started (\(duration)s)")
    }

    private func performAutoSave() {
        guard autoSaveCountdownActive else { return }
        cleanupAutoSaveState()
        saveComment(text: currentText, attachments: currentAttachments)
        debugLog("CommentInputController: Auto-saved voice comment")
    }

    public func cancelAutoSave() {
        guard autoSaveCountdownActive else { return }
        cleanupAutoSaveState()
        triggerSaveFeedback()
        debugLog("CommentInputController: Auto-save cancelled")
    }

    public func cancelAutoSaveCountdown() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        cleanupAutoSaveState()
    }

    private func cleanupAutoSaveState() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSaveCountdownActive = false
        autoSaveProgress = 0
        autoSaveRemainingSeconds = 0
        if let monitor = autoSaveClickMonitor {
            NSEvent.removeMonitor(monitor)
            autoSaveClickMonitor = nil
        }
    }

    public func showForWebElement(_ context: WebContext) {
        debugLog("CommentInput: showForWebElement called — \(context.displaySummary ?? "no summary")")
        SelectionTooltipWindowController.shared.dismiss()
        let regionRect = pendingRegionScreenRect
        guard let generation = beginDraft(
            elementWebContext: context,
            targetSessionID: PersistenceManager.shared.appState.activeSessionID
        ) else {
            pendingRegionScreenRect = nil
            WebSocketService.shared.dismissRegionHighlight()
            return
        }
        // Suppress click-outside briefly — the grab click in Chrome would
        // otherwise dismiss the panel immediately.
        suppressClickOutside = true
        pendingRegionScreenRect = nil
        show(near: regionRect, useAdjacentPositioning: regionRect != nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.draftGeneration == generation else { return }
            self.suppressClickOutside = false
        }
    }

    public func saveComment(text: String, attachments: [String] = [], wakeRequested: Bool = false) {
        // The panel remains onscreen for the 0.3s success animation. Refuse a
        // second key equivalent/button event after the draft has already ended;
        // otherwise its now-cleared context can be misclassified as a Quick Note.
        guard isVisible else {
            debugLog("CommentInputController: Save refused - no visible draft")
            return
        }

        let selection = currentSelection
        let isElementGrab = pendingElementWebContext != nil
        let source: String
        let type: CommentType

        if isScreenshotMode {
            source = "Screenshot"
            type = .screenshot(imagePath: screenshotImagePath ?? "")
        } else if isElementGrab {
            let context = pendingElementWebContext
            source = "Web Element"
            type = .webElement(componentName: context?.componentName, filePath: context?.filePath)
        } else if let selection {
            source = selection.source
            type = CommentSavePolicy.type(forSelectionText: selection.text)
        } else {
            source = "Quick Note"
            type = .quickNote
        }

        // Every explicit submission path (button, wake, and Command-Return)
        // converges here, so countdown cancellation cannot drift between them.
        cancelAutoSaveCountdown()

        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: text,
            attachments: attachments
        ) else {
            triggerSaveFeedback(announcement: "Add text to save this Quick Note")
            debugLog("CommentInputController: Empty Quick Note save refused")
            return
        }

        let normalizedText = Comment.normalizedCommentText(text)
        let savedTargetSessionID = targetSessionID
        let shouldWake = CommentWakePolicy.shouldWake(
            explicitlyRequested: wakeRequested,
            prearmed: wakeOnSave,
            targetIsReachable: SettingsManager.shared.wakeAvailable(for: savedTargetSessionID)
        )

        if isScreenshotMode {
            // Re-entrant save, wake-save, or dismissal is refused outright. The
            // comment UI can call all three while the 0.4s choreography runs.
            guard captureTransaction == .idle else {
                debugLog("CommentInputController: save refused - transaction is \(captureTransaction)")
                return
            }

            let draft = CaptureSaveDraft(
                commentText: normalizedText,
                attachments: attachments,
                sourceBundleID: screenshotSourceBundleID,
                targetSessionID: savedTargetSessionID,
                wakeRequested: shouldWake,
                captureRect: screenshotSelectionRect,
                anchorRect: panelAnchorRect,
                panelFrame: panel?.frame,
                shouldAttachWebContext: ScreenshotWebContextPolicy.allowsWebContext(
                    sourceBundleID: screenshotSourceBundleID
                )
            )

            // Region context is requested from the TRUE capture rect, never the
            // magnified one: a magnified rect would silently attach DOM context for
            // elements the user never selected.
            if let captureRect = draft.captureRect, draft.shouldAttachWebContext {
                WebSocketService.shared.requestRegionContext(
                    screenX: captureRect.origin.x,
                    screenY: captureRect.origin.y,
                    width: captureRect.width,
                    height: captureRect.height,
                    purpose: .screenshot
                )
            }

            captureTransaction = .preparing
            Task { [weak self] in await self?.runCaptureTransaction(draft: draft) }
            return
        }

        // Snapshot context before persistence, but consume it only after success so
        // a failed save leaves the composer fully retryable.
        let isChromium = selection?.appBundleID.flatMap { AppConstants.chromiumBundleIDs.contains($0) } ?? false
        if isChromium {
            WebSocketService.shared.clearPendingContextIfStale(olderThan: 120)
        }
        let webContext: WebContext? = if isChromium {
            WebSocketService.shared.pendingWebContext?.filtered()
        } else if let elementContext = pendingElementWebContext?.filtered() {
            elementContext
        } else {
            nil
        }
        let regionElements: [WebContext]? = if webContext != nil && isElementGrab {
            WebSocketService.shared.pendingRegionElements?.compactMap { $0.filtered() }
        } else {
            nil
        }

        // Suppress Combine badge updates until bounce plays the new count
        AppController.shared.prepareBadgeBounce()

        let comment = PersistenceManager.shared.createComment(
            type: type,
            commentText: normalizedText,
            source: source,
            appBundleID: selection?.appBundleID,
            attachments: attachments,
            webContext: webContext,
            regionElements: regionElements,
            targetSessionID: savedTargetSessionID,
            wakeRequested: shouldWake
        )

        guard let comment else {
            AppController.shared.cancelPreparedBadgeBounce()
            debugLog("CommentInputController: Comment save FAILED - no active session?")
            ToastManager.shared.show("Comment could not be saved")
            triggerSaveFeedback(announcement: "Comment could not be saved")
            return
        }

        if isChromium {
            _ = WebSocketService.shared.consumePendingWebContext(maxAge: 120)
        }
        if webContext != nil && isElementGrab {
            _ = WebSocketService.shared.consumePendingRegionElements(maxAge: 120)
        }
        if isElementGrab {
            WebSocketService.shared.dismissRegionHighlight()
            pendingElementWebContext = nil
        }

        debugLog("CommentInputController: Comment saved (id=\(comment.id))")

        dismissWithAnimation()
    }

    /// Animate scale-down + fade toward menu bar icon, then clean up
    private func dismissWithAnimation() {
        guard let panel = panel else {
            dismiss()
            return
        }
        heightCancellable?.cancel()
        removeClickOutsideMonitor()
        isVisible = false
        endDraftState()
        let completionGeneration = draftGeneration

        let targetPoint = menuBarTargetPoint()

        let frame = panel.frame
        let scale: CGFloat = 0.3
        let newWidth = frame.width * scale
        let newHeight = frame.height * scale

        // Animate toward menu bar icon position
        let newFrame = NSRect(
            x: targetPoint.x - newWidth / 2,
            y: targetPoint.y - newHeight / 2,
            width: newWidth,
            height: newHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(newFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                if let self,
                   self.draftGeneration == completionGeneration,
                   !self.isVisible {
                    panel?.orderOut(nil)
                    panel?.alphaValue = 1  // Reset for next show
                }
                AppController.shared.animateBadgeBounce()
            }
        }
    }

    public func dismiss() {
        // One layer per invocation. An inline text edit, toolbar focus, or a dirty
        // annotation session each consume this and nothing further happens.
        //
        // Ahead of the wakeOnSave reset on purpose: when annotation consumes the
        // dismissal the panel is not actually closing, so clearing the user's
        // wake choice there would discard a decision they never revoked.
        if routeDismissalThroughAnnotation(intent: .closeButton) { return }

        if isScreenshotMode {
            ScreenCaptureService.shared.cancelCapture()
        }
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        isVisible = false
        endDraftState()
    }

    // MARK: - Screenshot Reposition

    /// Thin caller over `AnnotationPanelGeometry`, so the math is unit-testable
    /// without exposing a private method and the Chrome element-grab caller below
    /// stays byte-identical: with no forced edge the pure type reproduces the three
    /// room tests, the unconditional below fallback, and the clamp exactly.
    private func screenshotPanelOrigin(
        captureRect: CGRect, panelSize: NSSize, screen: NSScreen,
        forcedEdge: StageDockEdge? = nil
    ) -> (origin: NSPoint, arrowEdge: Edge, isAbove: Bool) {
        let result = AnnotationPanelGeometry.origin(
            captureRect: captureRect, panelSize: panelSize,
            visibleFrame: screen.visibleFrame, margin: 8, clampInset: 4,
            forcedEdge: forcedEdge)
        return (NSPoint(x: result.origin.x, y: result.origin.y),
                Self.swiftUIEdge(result.edge), result.isAbove)
    }

    static func swiftUIEdge(_ edge: StageDockEdge) -> Edge {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    static func stageEdge(_ edge: Edge) -> StageDockEdge {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    // MARK: - Capture save transaction

    enum CaptureTransaction: Equatable {
        case idle, preparing, animating, creating, concluding
    }

    /// Save, wake-save, dismissal, annotate entry and exit, and zoom are all
    /// refused unless this is `.idle`.
    private(set) var captureTransaction: CaptureTransaction = .idle

    /// Everything needed to put the capture back exactly as it was. Retained for
    /// the whole transaction; nothing is cleared until finalize.
    struct CaptureSaveDraft {
        let commentText: String
        let attachments: [String]
        let sourceBundleID: String?
        let targetSessionID: UUID?
        /// Carried across the whole asynchronous fly sequence, because the wake
        /// path is live on capture today, not hypothetically.
        let wakeRequested: Bool
        /// The TRUE capture rect.
        let captureRect: CGRect?
        /// What the fly animation starts from: the magnified rect when magnified.
        let anchorRect: CGRect?
        let panelFrame: CGRect?
        let shouldAttachWebContext: Bool
    }

    private func runCaptureTransaction(draft: CaptureSaveDraft) async {
        let capture = ScreenCaptureService.shared

        let outcome = await capture.prepareCommit()
        let prepared: ScreenCaptureService.PreparedCapture
        switch outcome {
        case .failure(let error, let cleanup):
            // Nothing was mutated and every editor is still usable.
            capture.restore(token: nil, partial: cleanup)
            concludeWithRestore(message: error.localizedDescription)
            return
        case .success(let value):
            prepared = value
        }

        captureTransaction = .animating
        await runFlyChoreography(draft: draft, prepared: prepared)

        captureTransaction = .creating

        // Consume the pending web context where `commitScreenshot()` used to, and
        // publish it back to controller state so the badge and any retry can read
        // it - consumption clears the singleton.
        let webContext: WebContext?
        let regionElements: [WebContext]?
        if draft.shouldAttachWebContext {
            webContext = WebSocketService.shared.consumePendingWebContext(maxAge: 120)
            regionElements = webContext == nil
                ? nil
                : WebSocketService.shared.consumePendingRegionElements(maxAge: 120)
        } else {
            WebSocketService.shared.clearPendingContext()
            webContext = nil
            regionElements = nil
        }
        retainedWebContext = webContext
        retainedRegionElements = regionElements

        AppController.shared.prepareBadgeBounce()

        let result = await PersistenceManager.shared.createCommentDurably(
            type: .screenshot(imagePath: prepared.relativePath),
            commentText: draft.commentText,
            source: "Screenshot",
            appBundleID: draft.sourceBundleID,
            attachments: draft.attachments,
            webContext: webContext,
            regionElements: regionElements,
            targetSessionID: draft.targetSessionID,
            wakeRequested: draft.wakeRequested
        )

        captureTransaction = .concluding
        switch result {
        case .success(let comment):
            debugLog("CommentInputController: Screenshot comment durably saved (id=\(comment.id))")
            // The caller never touches the lease: finalize and restore are its only
            // owners and exactly one of them runs.
            capture.finalize(token: prepared.token, prepared: prepared)
            finishAfterDurableSuccess()
        case .failure(let error):
            debugLog("CommentInputController: Durable save failed - \(error)")
            capture.restore(token: prepared.token, prepared: prepared)
            AppController.shared.cancelPreparedBadgeBounce()
            concludeWithRestore(message: error.userMessage)
        }
        captureTransaction = .idle
    }

    /// The panel genies toward the menu bar and the stage flies after it, exactly
    /// as before, except the fly panel now shows the **prepared final image**
    /// rather than taking its own independent grab.
    private func runFlyChoreography(draft: CaptureSaveDraft,
                                    prepared: ScreenCaptureService.PreparedCapture) async {
        guard let panelRef = panel else { return }

        heightCancellable?.cancel()
        removeClickOutsideMonitor()
        lastPanelFrameBeforeFly = panelRef.frame
        let targetPoint = menuBarTargetPoint()

        // Phase 1: comment panel genies toward the menu bar.
        let frame = panelRef.frame
        let scale: CGFloat = 0.3
        let shrunk = NSRect(x: targetPoint.x - frame.width * scale / 2,
                            y: targetPoint.y - frame.height * scale / 2,
                            width: frame.width * scale, height: frame.height * scale)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
            panelRef.animator().setFrame(shrunk, display: true)
        } completionHandler: {
            panelRef.orderOut(nil)
        }

        // Phase 2: overlay fades. The toolbar is ordered out FIRST, so the fly
        // panel can reuse .screenSaver + 2 without contending for it.
        ScreenCaptureService.shared.orderOutToolbarForCommit()
        let overlayRef = ScreenCaptureService.shared.overlayPanel
        // Explicit completion handler disambiguates from the `async` overload,
        // which Swift would otherwise prefer inside this async function.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlayRef?.animator().alphaValue = 0
        } completionHandler: { }

        // Phase 3: the stage flies toward the menu bar, showing the exact image
        // that was just written.
        guard let anchor = draft.anchorRect else {
            try? await Task.sleep(for: .milliseconds(200))
            return
        }

        let flyPanel = NSPanel(contentRect: anchor,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        flyPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        flyPanel.backgroundColor = .clear
        flyPanel.isOpaque = false
        flyPanel.hasShadow = false
        flyPanel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: anchor.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = AppConstants.panelCornerRadius
        content.layer?.masksToBounds = true
        content.layer?.borderColor = NSColor.white.cgColor
        content.layer?.borderWidth = 1.5

        let imageLayer = CALayer()
        imageLayer.frame = content.bounds
        imageLayer.contents = prepared.cgImage
        // `.resize`, not `.resizeAspectFill`: the aspect can drift between the
        // magnified anchor and the source pixels, and aspect-fill crops on drift.
        imageLayer.contentsGravity = .resize
        imageLayer.cornerRadius = AppConstants.panelCornerRadius
        imageLayer.masksToBounds = true
        content.layer?.addSublayer(imageLayer)

        flyPanel.contentView = content
        flyPanel.setFrame(anchor, display: true)
        flyPanel.orderFront(nil)

        let borderScale: CGFloat = 0.08
        let target = NSRect(x: targetPoint.x - anchor.width * borderScale / 2,
                            y: targetPoint.y - anchor.height * borderScale / 2,
                            width: anchor.width * borderScale,
                            height: anchor.height * borderScale)

        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                flyPanel.animator().alphaValue = 0
                flyPanel.animator().setFrame(target, display: true)
            } completionHandler: {
                flyPanel.orderOut(nil)
                // The animation is cosmetic. Never abort the save because of it.
                continuation.resume()
            }
        }
    }

    private func finishAfterDurableSuccess() {
        // A successful save never reaches dismiss(), so the monitor has to come
        // down here or it survives into the next capture and every one after.
        isVisible = false
        endDraftState()
        retainedWebContext = nil
        retainedRegionElements = nil
        panel?.alphaValue = 1
        if let restoreFrame = lastPanelFrameBeforeFly { panel?.setFrame(restoreFrame, display: false) }
        lastPanelFrameBeforeFly = nil
        AppController.shared.animateBadgeBounce()
    }

    /// Put the capture back: panel frames, alpha, visibility, focus, and the two
    /// monitors the choreography removed.
    private func concludeWithRestore(message: String) {
        if let panel {
            panel.alphaValue = 1
            if let frame = lastPanelFrameBeforeFly { panel.setFrame(frame, display: true) }
            panel.makeKeyAndOrderFront(nil)
        }
        ScreenCaptureService.shared.overlayPanel?.alphaValue = 1
        ScreenCaptureService.shared.restoreToolbarAfterFailedCommit()

        // Reinstall what the choreography removed, or the panel never resizes with
        // typing again and clicking outside stops dismissing it.
        setupHeightObserver()
        installClickOutsideMonitor()
        makeCommentPanelKey()

        ToastManager.shared.show(message)
        captureTransaction = .idle
    }

    // MARK: - Annotation anchoring API

    /// 340 lives in four places that must agree; this is the one the stage math
    /// reads. `panelReserve` = margin (8) + panel width (340) + clamp inset (4).
    static let panelWidthConstant: CGFloat = 340
    static let panelReserve: CGFloat = 8 + panelWidthConstant + 4

    /// The dock edge the stage must respect, snapshotted at annotate-entry.
    var frozenStageEdge: StageDockEdge? {
        (frozenArrowEdge ?? arrowEdge).map { Self.stageEdge($0) }
    }

    func beginAnnotationAnchoring(displayRectScreen rect: CGRect) {
        frozenArrowEdge = arrowEdge
        annotationActive = true
        setAnnotationDisplayRect(rect)
    }

    /// Takes a SCREEN-GLOBAL rect. Re-runs the panel geometry with the frozen edge,
    /// sets the origin, and rebuilds the VEV mask **unconditionally**: the arrow
    /// fraction does not necessarily change under centred growth - unclamped it is
    /// 0.5 before and after - but it may change near clamps.
    func setAnnotationDisplayRect(_ rect: CGRect?) {
        displayRectScreen = rect
        guard let panel, let anchor = panelAnchorRect else { return }

        let midpoint = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) })
                ?? NSScreen.main else { return }

        let pos = screenshotPanelOrigin(captureRect: anchor, panelSize: panel.frame.size,
                                        screen: screen, forcedEdge: frozenStageEdge)
        isAboveSelection = pos.isAbove
        arrowEdge = pos.arrowEdge
        panel.setFrameOrigin(pos.origin)
        updateVEVMask()
        panel.invalidateShadow()
        keepCommentPanelAboveSelectionOverlay()
    }

    /// Hand keyboard focus back to the comment field.
    ///
    /// Used when annotation finishes editing: the overlay took key status so the
    /// canvas could own tool shortcuts, and the user now needs to type.
    func focusCommentField() {
        makeCommentPanelKey()
    }

    func endAnnotationAnchoring() {
        annotationActive = false
        displayRectScreen = nil
        frozenArrowEdge = nil
    }

    public func repositionForScreenshot(captureRect: CGRect, restoreFocus: Bool = true) {
        guard isScreenshotMode, let panel = panel else { return }
        // Region geometry is locked once a frozen session exists. A late live-drag
        // callback arriving here would move the panel off the stage.
        guard !annotationActive else { return }
        screenshotSelectionRect = captureRect

        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: captureRect.midX, y: captureRect.midY))
        }) ?? NSScreen.main
        guard let screen = screen else { return }

        let previousEdge = arrowEdge
        let pos = screenshotPanelOrigin(captureRect: captureRect, panelSize: panel.frame.size, screen: screen)
        isAboveSelection = pos.isAbove
        arrowEdge = pos.arrowEdge
        panel.setFrameOrigin(pos.origin)

        if restoreFocus {
            updateVEVMask()
            panel.invalidateShadow()
            makeCommentPanelKey()
        } else if arrowEdge != previousEdge {
            // During drag, only rebuild mask if the panel flipped sides
            updateVEVMask()
        }
        keepCommentPanelAboveSelectionOverlay()
    }

    private func makeCommentPanelKey() {
        guard let panel = panel else { return }
        panel.makeKeyAndOrderFront(nil)
        keepCommentPanelAboveSelectionOverlay()
        // Defer so the panel is key before we try to set first responder
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let panel = self.panel else { return }
            if let scrollView = self.findScrollView(in: panel.contentView),
               let textView = scrollView.documentView as? NSTextView {
                panel.makeFirstResponder(textView)
                self.keepCommentPanelAboveSelectionOverlay()
            }
        }
    }

    private func keepCommentPanelAboveSelectionOverlay() {
        guard isScreenshotMode, let panel else { return }
        panel.level = screenshotPanelLevel

        guard let overlayPanel = ScreenCaptureService.shared.overlayPanel,
              overlayPanel.isVisible,
              overlayPanel.windowNumber > 0
        else { return }

        panel.order(.above, relativeTo: overlayPanel.windowNumber)
    }

    private func show(near rect: CGRect?, useAdjacentPositioning: Bool = false) {
        // Re-check before the composer appears: sessions start and end while
        // the app is running, so a cached answer goes stale quickly.
        SettingsManager.shared.refreshWakeReachability()
        if panel == nil {
            let panel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true

            // NSVisualEffectView as contentView — provides material backdrop
            let vev = NSVisualEffectView()
            vev.material = .popover
            vev.blendingMode = .behindWindow
            vev.state = .active
            panel.contentView = vev

            let view = CommentInputView()
                .environmentObject(self)

            let hostingView = NSHostingView(rootView: view)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            vev.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: vev.topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: vev.bottomAnchor),
            ])

            self.panel = panel
            self.panelVEV = vev
            self.panelHostingView = hostingView
        }

        // Reset panel size — may have been shrunk by genie animation on previous save
        panel?.setContentSize(NSSize(width: panelWidth, height: 180))

        // Set panel level — above overlay in screenshot mode, floating otherwise
        panel?.level = isScreenshotMode
            ? screenshotPanelLevel
            : .floating

        arrowEdge = nil  // Reset; set in screenshot positioning below

        // Position near selection or center on screen
        if let rect = rect {
            let margin: CGFloat = 8
            let panelFrame = panel!.frame
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) ?? NSScreen.main

            if (isScreenshotMode || useAdjacentPositioning), let screen = screen {
                let pos = screenshotPanelOrigin(captureRect: rect, panelSize: panelFrame.size, screen: screen)
                isAboveSelection = pos.isAbove
                arrowEdge = pos.arrowEdge
                panel?.setFrameOrigin(pos.origin)
            } else {
                // Text selection mode: above or below
                var origin = NSPoint(
                    x: rect.midX - (panelFrame.width / 2),
                    y: rect.maxY + margin
                )
                isAboveSelection = true

                if let screen = screen {
                    if origin.y + panelFrame.height > screen.visibleFrame.maxY {
                        origin.y = rect.minY - panelFrame.height - margin
                        isAboveSelection = false
                    }
                    origin.x = max(screen.visibleFrame.minX + 8,
                                  min(origin.x, screen.visibleFrame.maxX - panelFrame.width - 8))
                }
                panel?.setFrameOrigin(origin)
            }
        } else {
            isAboveSelection = true
            panel?.center()
        }

        updateVEVMask()

        isVisible = true
        // Start invisible — fade in after the first height measurement to avoid visible resize
        panel?.alphaValue = 0
        pendingFadeIn = true
        panel?.makeKeyAndOrderFront(nil)
        keepCommentPanelAboveSelectionOverlay()
        installClickOutsideMonitor()
        setupHeightObserver()

        // Defer initial height measurement so SwiftUI has laid out first
        DispatchQueue.main.async { [weak self] in self?.updatePanelHeight() }

        // Ensure the text view gets first responder after the view hierarchy is set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let panel = self?.panel else { return }
            if let scrollView = self?.findScrollView(in: panel.contentView),
               let textView = scrollView.documentView as? NSTextView {
                panel.makeFirstResponder(textView)
            }
        }
    }

    // MARK: - Dynamic Height

    private func setupHeightObserver() {
        heightCancellable?.cancel()
        heightCancellable = Publishers.Merge3(
            $currentText.map { _ in () },
            $currentAttachments.map { _ in () },
            $currentSelection.map { _ in () }
        )
        .sink { [weak self] _ in
            // Defer to next run loop so SwiftUI has finished its layout pass
            // and fittingSize returns the correct value.
            DispatchQueue.main.async { self?.updatePanelHeight() }
        }
    }

    private var lastPanelHeight: CGFloat = 0

    private func updatePanelHeight() {
        guard let panel = panel, let hostingView = panelHostingView else { return }
        defer {
            // The Annotate control stays disabled until the panel has a real size:
            // the stage allowance reserves `panelReserve`, and computing it from a
            // stale frame would size the stage wrongly.
            if isScreenshotMode && !panelLayoutReady {
                panelLayoutReady = true
                onPanelLayoutReady?()
            }
        }
        let fittingSize = hostingView.fittingSize
        // Round to whole points to prevent sub-pixel oscillation between layout passes
        let idealHeight = ceil(max(minPanelHeight, min(fittingSize.height, maxPanelHeight)))
        let currentFrame = panel.frame

        let needsResize = abs(currentFrame.height - idealHeight) > 2

        if needsResize {
            var newFrame = currentFrame
            newFrame.size.height = idealHeight

            if let selRect = panelAnchorRect,
               (arrowEdge == .leading || arrowEdge == .trailing) {
                // Panel is beside selection — re-center vertically on selection
                // so the arrow stays at the panel's midpoint.
                newFrame.origin.y = selRect.midY - idealHeight / 2
                // Clamp to screen
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: selRect.midX, y: selRect.midY)) }) ?? NSScreen.main {
                    newFrame.origin.y = max(screen.visibleFrame.minY + 4,
                                           min(newFrame.origin.y, screen.visibleFrame.maxY - idealHeight - 4))
                }
            } else if isAboveSelection {
                // Panel is above selection — anchor bottom edge (keep origin.y fixed,
                // top moves up). In AppKit coords origin is bottom-left.
            } else {
                // Panel is below selection — anchor top edge so it stays
                // aligned with the selection's top. Adjust origin.y so the top
                // (origin.y + height) remains constant.
                newFrame.origin.y = currentFrame.origin.y + currentFrame.height - idealHeight
            }

            let isGrowing = idealHeight > lastPanelHeight
            lastPanelHeight = idealHeight

            if isGrowing || pendingFadeIn {
                // Instant resize (no text clipping; also no animation on first show)
                panel.setFrame(newFrame, display: true, animate: false)
                updateVEVMask()
                panel.invalidateShadow()
                keepCommentPanelAboveSelectionOverlay()
            } else {
                // Animated shrink
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(newFrame, display: true)
                } completionHandler: { [weak self] in
                    Task { @MainActor in
                        self?.updateVEVMask()
                        self?.panel?.invalidateShadow()
                        self?.keepCommentPanelAboveSelectionOverlay()
                    }
                }
            }
        }

        // Fade in once after the first height measurement
        if pendingFadeIn {
            pendingFadeIn = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Click Outside Monitor

    private func installClickOutsideMonitor() {
        guard let panel else { return }
        clickOutsideMonitor.install(
            for: panel,
            shouldDismiss: { [weak self] in
                guard let self else { return true }
                return !self.suppressClickOutside
                    && !self.isScreenshotMode
                    && self.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && self.currentAttachments.isEmpty
            },
            dismiss: { [weak self] in self?.dismiss() }
        )
    }

    private func removeClickOutsideMonitor() {
        clickOutsideMonitor.remove()
    }

    // MARK: - VEV Mask

    private func updateVEVMask() {
        guard let vev = panelVEV, let panel = panel else { return }
        let frame = panel.frame
        guard frame.width > 0, frame.height > 0 else { return }

        if let edge = arrowEdge {
            // Recalculate arrow fraction from current panel frame + selection rect
            // so the arrow tracks the selection center even after height changes.
            let fraction: CGFloat
            if let selRect = panelAnchorRect {
                let cr = AppConstants.panelCornerRadius
                let minFrac = (cr + 8) / max(frame.height, 1)
                let maxFrac = 1 - minFrac
                switch edge {
                case .leading, .trailing:
                    let relY = selRect.midY - frame.origin.y
                    fraction = max(minFrac, min(relY / frame.height, maxFrac))
                case .top, .bottom:
                    let relX = selRect.midX - frame.origin.x
                    fraction = max(minFrac, min(relX / frame.width, maxFrac))
                }
            } else {
                fraction = 0.5
            }

            vev.maskImage = Self.tooltipMaskImage(
                size: frame.size,
                cornerRadius: AppConstants.panelCornerRadius,
                arrowEdge: edge,
                arrowFraction: fraction
            )
        } else {
            vev.maskImage = .roundedRectMask(cornerRadius: AppConstants.panelCornerRadius)
        }
    }


    /// Fixed-size tooltip-shaped mask (regenerated on resize).
    private static func tooltipMaskImage(size: NSSize, cornerRadius: CGFloat, arrowEdge: Edge, arrowFraction: CGFloat = 0.5) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let cgPath = tooltipCGPath(
                in: rect, cornerRadius: cornerRadius, arrowEdge: arrowEdge, arrowFraction: arrowFraction
            )
            ctx.addPath(cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
    }

    /// CGPath for tooltip shape. `arrowFraction` (0…1) positions the arrow along the edge.
    /// In the flipped (SwiftUI) coordinate system used by maskImage.
    private static func tooltipCGPath(
        in rect: CGRect,
        cornerRadius: CGFloat,
        arrowEdge: Edge,
        arrowFraction: CGFloat = 0.5,
        arrowWidth: CGFloat = 14,
        arrowDepth: CGFloat = 7
    ) -> CGPath {
        let cr = cornerRadius
        let halfArrow = arrowWidth / 2
        let tipR: CGFloat = 1.5

        let body: CGRect
        switch arrowEdge {
        case .leading:
            body = CGRect(x: rect.minX + arrowDepth, y: rect.minY,
                         width: rect.width - arrowDepth, height: rect.height)
        case .trailing:
            body = CGRect(x: rect.minX, y: rect.minY,
                         width: rect.width - arrowDepth, height: rect.height)
        case .top:
            body = CGRect(x: rect.minX, y: rect.minY + arrowDepth,
                         width: rect.width, height: rect.height - arrowDepth)
        case .bottom:
            body = CGRect(x: rect.minX, y: rect.minY,
                         width: rect.width, height: rect.height - arrowDepth)
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + cr, y: body.minY))

        // Arrow position along each edge.
        // For horizontal edges: arrowFraction maps directly (0=left, 1=right).
        // For vertical edges: the mask is drawn flipped, so invert the fraction
        // (AppKit 0=bottom→flipped 0=top).
        let hPos = body.minX + arrowFraction * body.width   // horizontal position
        let vPos = body.minY + (1 - arrowFraction) * body.height  // vertical position (flipped)

        // -- Top edge --
        if arrowEdge == .top {
            let ax = hPos
            path.addLine(to: CGPoint(x: ax - halfArrow, y: body.minY))
            path.addCurve(to: CGPoint(x: ax, y: rect.minY),
                         control1: CGPoint(x: ax - halfArrow * 0.3, y: body.minY),
                         control2: CGPoint(x: ax - tipR, y: rect.minY))
            path.addCurve(to: CGPoint(x: ax + halfArrow, y: body.minY),
                         control1: CGPoint(x: ax + tipR, y: rect.minY),
                         control2: CGPoint(x: ax + halfArrow * 0.3, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.maxX - cr, y: body.minY))

        // Top-right corner
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                   tangent2End: CGPoint(x: body.maxX, y: body.minY + cr),
                   radius: cr)

        // -- Right edge --
        if arrowEdge == .trailing {
            let ay = vPos
            path.addLine(to: CGPoint(x: body.maxX, y: ay - halfArrow))
            path.addCurve(to: CGPoint(x: rect.maxX, y: ay),
                         control1: CGPoint(x: body.maxX, y: ay - halfArrow * 0.3),
                         control2: CGPoint(x: rect.maxX, y: ay - tipR))
            path.addCurve(to: CGPoint(x: body.maxX, y: ay + halfArrow),
                         control1: CGPoint(x: rect.maxX, y: ay + tipR),
                         control2: CGPoint(x: body.maxX, y: ay + halfArrow * 0.3))
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - cr))

        // Bottom-right corner
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                   tangent2End: CGPoint(x: body.maxX - cr, y: body.maxY),
                   radius: cr)

        // -- Bottom edge --
        if arrowEdge == .bottom {
            let ax = hPos
            path.addLine(to: CGPoint(x: ax + halfArrow, y: body.maxY))
            path.addCurve(to: CGPoint(x: ax, y: rect.maxY),
                         control1: CGPoint(x: ax + halfArrow * 0.3, y: body.maxY),
                         control2: CGPoint(x: ax + tipR, y: rect.maxY))
            path.addCurve(to: CGPoint(x: ax - halfArrow, y: body.maxY),
                         control1: CGPoint(x: ax - tipR, y: rect.maxY),
                         control2: CGPoint(x: ax - halfArrow * 0.3, y: body.maxY))
        }
        path.addLine(to: CGPoint(x: body.minX + cr, y: body.maxY))

        // Bottom-left corner
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                   tangent2End: CGPoint(x: body.minX, y: body.maxY - cr),
                   radius: cr)

        // -- Left edge --
        if arrowEdge == .leading {
            let ay = vPos
            path.addLine(to: CGPoint(x: body.minX, y: ay + halfArrow))
            path.addCurve(to: CGPoint(x: rect.minX, y: ay),
                         control1: CGPoint(x: body.minX, y: ay + halfArrow * 0.3),
                         control2: CGPoint(x: rect.minX, y: ay + tipR))
            path.addCurve(to: CGPoint(x: body.minX, y: ay - halfArrow),
                         control1: CGPoint(x: rect.minX, y: ay - tipR),
                         control2: CGPoint(x: body.minX, y: ay - halfArrow * 0.3))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + cr))

        // Top-left corner
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                   tangent2End: CGPoint(x: body.minX + cr, y: body.minY),
                   radius: cr)

        path.closeSubpath()
        return path
    }

    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view = view else { return nil }
        if let scrollView = view as? NSScrollView,
           scrollView.documentView is NSTextView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
