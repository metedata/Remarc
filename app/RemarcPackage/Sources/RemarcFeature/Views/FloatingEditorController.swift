import AppKit
import Combine
import SwiftUI

private class KeyableEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            if FloatingEditorController.shared.autoSaveCountdownActive {
                FloatingEditorController.shared.cancelAutoSave()
            } else {
                FloatingEditorController.shared.dismiss()
            }
        }
    }
}

@MainActor
public final class FloatingEditorController: ObservableObject {
    public static let shared = FloatingEditorController()

    @Published public var isVisible: Bool = false
    @Published public var currentText: String = ""
    @Published public var currentAttachments: [String] = []
    @Published public var targetSessionID: UUID?
    @Published public var pendingVoiceText: String?
    @Published public var autoSaveCountdownActive: Bool = false
    @Published public var autoSaveProgress: Double = 0
    @Published public var autoSaveRemainingSeconds: Int = 0
    @Published public private(set) var saveFeedbackTrigger: Int = 0
    @Published public private(set) var validationFeedbackTrigger: Int = 0
    @Published public var isSaveButtonHovered: Bool = false
    public var suppressClickOutside: Bool = false

    private var panel: NSPanel?
    private var editorHostingView: NSHostingView<FloatingEditorWrapper>?
    private var dimOverlay: NSPanel?
    private let clickOutsideMonitor = ClickOutsideMonitor()
    private var contentCancellable: AnyCancellable?
    private var initialText: String = ""
    private var initialAttachments: [String] = []
    private var isVoiceInvoked: Bool = false
    private var allowsVoiceAutoSave: Bool = false
    private var currentCommentType: CommentType?
    private var currentSaveAction: ((String, [String]) -> Bool)?
    private var currentSuccessMessage: String?
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveClickMonitor: Any?
    private var presentationGeneration: UInt64 = 0

    public var currentPresentationGeneration: UInt64 { presentationGeneration }

    private var hasUnsavedChanges: Bool {
        currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialText.trimmingCharacters(in: .whitespacesAndNewlines)
            || currentAttachments != initialAttachments
    }

    /// Show editor for editing an existing comment
    public func showForEdit(comment: Comment) {
        show(
            referenceText: comment.type.displayText,
            screenshotImagePath: comment.type.imagePath,
            comment: comment,
            initialText: comment.commentText,
            initialAttachments: comment.attachments,
            commentType: comment.type,
            targetSessionID: comment.sessionID,
            successMessage: "Comment updated",
            onSave: { newText, newAttachments in
                PersistenceManager.shared.updateComment(
                    comment.id,
                    text: newText,
                    attachments: newAttachments
                )
            }
        )
    }

    /// Show editor for creating a quick note
    public func showForQuickNote() {
        show(
            referenceText: nil,
            screenshotImagePath: nil,
            comment: nil,
            initialText: "",
            initialAttachments: [],
            commentType: .quickNote,
            targetSessionID: PersistenceManager.shared.appState.activeSessionID,
            successMessage: "Quick note saved",
            onSave: { text, attachments in
                PersistenceManager.shared.createComment(
                    type: .quickNote,
                    commentText: text,
                    source: "Quick Note",
                    appBundleID: nil,
                    attachments: attachments,
                    targetSessionID: self.targetSessionID
                ) != nil
            }
        )
    }

    /// Temporarily hide editor and dim overlay so system dialogs (NSOpenPanel) appear unobstructed.
    /// NSOpenPanel runs out-of-process and its window level cannot be controlled by the host app.
    public func orderOutForSystemDialog() {
        panel?.orderOut(nil)
        dimOverlay?.orderOut(nil)
    }

    /// Re-show editor and dim overlay after a system dialog is dismissed.
    public func orderFrontAfterSystemDialog() {
        dimOverlay?.orderFront(nil)
        panel?.makeKeyAndOrderFront(nil)
    }

    public func appendVoiceText(_ text: String, forPresentationGeneration generation: UInt64) {
        guard acceptsVoiceTranscription(generation) else {
            debugLog("FloatingEditorController: Discarded transcription for stale presentation")
            return
        }
        pendingVoiceText = text
    }

    public func markVoiceInvoked() {
        isVoiceInvoked = true
    }

    func isCurrentPresentation(_ generation: UInt64) -> Bool {
        presentationGeneration == generation
    }

    func acceptsVoiceTranscription(_ generation: UInt64) -> Bool {
        DraftGenerationPolicy.accepts(
            capturedGeneration: generation,
            currentGeneration: presentationGeneration,
            isVisible: isVisible
        )
    }

    private func attemptSave(text: String, attachments: [String]) {
        // Button, Command-Return, and voice auto-save all converge here.
        cancelAutoSaveCountdown()

        guard let type = currentCommentType,
              let saveAction = currentSaveAction
        else {
            debugLog("FloatingEditorController: Save refused - no active draft")
            return
        }

        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: text,
            attachments: attachments
        ) else {
            triggerSaveFeedback(announcement: "Add text to save this Quick Note")
            debugLog("FloatingEditorController: Empty Quick Note save refused")
            return
        }

        guard saveAction(text, attachments) else {
            ToastManager.shared.show("Comment could not be saved")
            triggerSaveFeedback(announcement: "Comment could not be saved")
            debugLog("FloatingEditorController: Comment save failed")
            return
        }

        if let currentSuccessMessage {
            ToastManager.shared.show(currentSuccessMessage)
        }
        dismiss()
    }

    private func triggerSaveFeedback(announcement: String? = nil) {
        saveFeedbackTrigger &+= 1
        guard let announcement else { return }
        validationFeedbackTrigger &+= 1
        panel?.makeKeyAndOrderFront(nil)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Auto-Save Voice Notes

    public func startAutoSaveCountdown() {
        guard VoiceAutoSavePolicy.shouldStartCountdown(
            isVoiceInvoked: isVoiceInvoked,
            autoSaveEnabled: SettingsManager.shared.autoSaveVoiceNotes,
            text: currentText,
            allowsAutoSave: allowsVoiceAutoSave
        )
        else { return }

        cancelAutoSaveCountdown()
        autoSaveCountdownActive = true
        autoSaveProgress = 0

        let duration = SettingsManager.shared.autoSaveDelay.duration
        autoSaveRemainingSeconds = Int(ceil(duration))

        autoSaveClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, !self.isSaveButtonHovered else { return event }
            self.cancelAutoSave()
            return event
        }

        let steps = max(1, Int(duration * 60))
        let interval = duration / Double(steps)
        let start = Date()

        autoSaveTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled else { return }
                let progress = Double(i) / Double(steps)
                self?.autoSaveProgress = progress

                let elapsed = Date().timeIntervalSince(start)
                let remaining = max(0, Int(ceil(duration - elapsed)))
                if remaining != self?.autoSaveRemainingSeconds {
                    self?.autoSaveRemainingSeconds = remaining
                }
            }

            guard !Task.isCancelled else { return }
            self?.performAutoSave()
        }

        debugLog("FloatingEditorController: Auto-save countdown started (\(duration)s)")
    }

    private func performAutoSave() {
        guard autoSaveCountdownActive, currentSaveAction != nil else { return }
        let text = currentText
        let attachments = currentAttachments
        cleanupAutoSaveState()
        attemptSave(text: text, attachments: attachments)
        debugLog("FloatingEditorController: Auto-saved voice quick note")
    }

    public func cancelAutoSave() {
        guard autoSaveCountdownActive else { return }
        cleanupAutoSaveState()
        triggerSaveFeedback()
        debugLog("FloatingEditorController: Auto-save cancelled")
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

    private func resetDraftState() {
        cancelAutoSaveCountdown()
        if #available(macOS 26, *) {
            VoiceInputService.shared.cancelRecording()
        }
        pendingVoiceText = nil
        isVoiceInvoked = false
        allowsVoiceAutoSave = false
        currentCommentType = nil
        currentSaveAction = nil
        currentSuccessMessage = nil
        currentText = ""
        initialText = ""
        currentAttachments = []
        initialAttachments = []
        targetSessionID = nil
        saveFeedbackTrigger = 0
        validationFeedbackTrigger = 0
        isSaveButtonHovered = false
        suppressClickOutside = false
    }

    public func dismiss() {
        presentationGeneration &+= 1
        clickOutsideMonitor.remove()
        contentCancellable?.cancel()
        contentCancellable = nil
        isVisible = false
        resetDraftState()

        let panelRef = panel
        let overlayRef = dimOverlay

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef?.animator().alphaValue = 0
            overlayRef?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panelRef?.orderOut(nil)
                panelRef?.alphaValue = 1
                overlayRef?.orderOut(nil)
                overlayRef?.alphaValue = 1
                // Only release references if they still point at this dismissed
                // presentation. A replacement editor may already own new panels.
                if self?.panel === panelRef {
                    self?.panel = nil
                    self?.editorHostingView = nil
                }
                if self?.dimOverlay === overlayRef {
                    self?.dimOverlay = nil
                }
            }
        }
    }

    private func show(
        referenceText: String?,
        screenshotImagePath: String?,
        comment: Comment?,
        initialText: String,
        initialAttachments: [String],
        commentType: CommentType,
        targetSessionID: UUID?,
        successMessage: String,
        onSave: @escaping (String, [String]) -> Bool
    ) {
        // Dismiss any previous editor
        dismiss()
        presentationGeneration &+= 1
        let generation = presentationGeneration

        // Track text and attachments for click-outside dismiss behavior
        self.initialText = initialText
        self.currentText = initialText
        self.initialAttachments = initialAttachments
        self.currentAttachments = initialAttachments
        self.pendingVoiceText = nil
        self.isVoiceInvoked = false
        self.allowsVoiceAutoSave = comment == nil
        self.currentCommentType = commentType
        self.currentSaveAction = onSave
        self.currentSuccessMessage = successMessage
        self.targetSessionID = targetSessionID
        self.saveFeedbackTrigger = 0
        self.validationFeedbackTrigger = 0

        // Create dim overlay on top of the popover
        installDimOverlay(generation: generation)

        // Create editor panel
        let wrapper = FloatingEditorWrapper(
            presentationGeneration: generation,
            initialText: initialText,
            initialAttachments: initialAttachments,
            screenshotImagePath: screenshotImagePath,
            referenceText: referenceText,
            comment: comment,
            onSave: { [weak self] text, attachments in
                guard let self, self.presentationGeneration == generation else { return }
                self.attemptSave(text: text, attachments: attachments)
            },
            onCancel: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
            }
        )

        let panel = KeyableEditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.editorWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        // NSVisualEffectView as contentView with maskImage — same pattern as popover.
        // This tells the window server the rounded shape for correct backdrop blur compositing.
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.maskImage = .roundedRectMask(cornerRadius: AppConstants.panelCornerRadius)
        panel.contentView = visualEffectView

        // NSHostingView as subview of VEV — NO SwiftUI material backgrounds.
        let hostingView = NSHostingView(rootView: wrapper)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // Measure ideal size first, then size the panel to fit
        let fittingSize = hostingView.fittingSize
        panel.setContentSize(fittingSize)

        // Pin with Auto Layout
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        self.editorHostingView = hostingView

        // Position centered over the popover, fade in
        positionEditorPanel(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        isVisible = true
        clickOutsideMonitor.install(
            for: panel,
            shouldDismiss: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return false }
                return !self.suppressClickOutside && !self.hasUnsavedChanges
            },
            dismiss: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
            }
        )
        installContentObserver()
    }

    private func positionEditorPanel(_ panel: NSPanel) {
        guard let popoverPanel = getPopoverPanel() else {
            panel.center()
            return
        }

        let popoverFrame = popoverPanel.frame

        // Center the editor over the popover panel
        let editorX = popoverFrame.midX - panel.frame.width / 2
        let editorY = popoverFrame.midY - panel.frame.height / 2

        // Clamp to the screen the popover is actually on, not NSScreen.main
        let screen = NSScreen.bestScreen(for: popoverPanel)
        let screenFrame = screen.visibleFrame
        let clampedX = max(screenFrame.minX + 8, min(editorX, screenFrame.maxX - panel.frame.width - 8))
        let clampedY = max(screenFrame.minY + 8, min(editorY, screenFrame.maxY - panel.frame.height - 8))

        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    private func installDimOverlay(generation: UInt64) {
        guard let popoverPanel = getPopoverPanel() else { return }

        let overlay = NSPanel(
            contentRect: popoverPanel.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = false  // Receives clicks to block popover interaction
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.animationBehavior = .none

        // Custom NSView that draws a rounded dim and dismisses the editor on click
        let dimView = DimOverlayContentView(cornerRadius: AppConstants.panelCornerRadius)
        dimView.onMouseDown = { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.hasUnsavedChanges
                else { return }
                self.dismiss()
            }
        }
        overlay.contentView = dimView

        // Inset the overlay to cover only the popover body, excluding the arrow area.
        // The arrow occupies the top `popoverArrowHeight` of the frame (highest y in screen coords).
        let arrowH = AppConstants.popoverArrowHeight
        let bodyFrame = NSRect(
            x: popoverPanel.frame.origin.x,
            y: popoverPanel.frame.origin.y,
            width: popoverPanel.frame.width,
            height: popoverPanel.frame.height - arrowH
        )
        overlay.setFrame(bodyFrame, display: true)
        overlay.alphaValue = 0
        overlay.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 1
        }

        self.dimOverlay = overlay
    }

    // MARK: - Content Size Observer

    private func installContentObserver() {
        contentCancellable?.cancel()
        contentCancellable = Publishers.Merge(
            $currentText.map { _ in () },
            $currentAttachments.map { _ in () }
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.resizePanelToFit()
        }
    }

    private func resizePanelToFit() {
        guard let panel = panel, let hostingView = editorHostingView else { return }
        let fittingSize = hostingView.fittingSize
        let currentFrame = panel.frame
        guard abs(currentFrame.height - fittingSize.height) > 1 else { return }

        // Keep the panel centered vertically around the same midpoint
        let newY = currentFrame.midY - fittingSize.height / 2

        let screen = NSScreen.bestScreen(for: panel)
        let screenFrame = screen.visibleFrame
        let clampedY = max(screenFrame.minY + 8, min(newY, screenFrame.maxY - fittingSize.height - 8))

        let newFrame = NSRect(x: currentFrame.origin.x, y: clampedY,
                              width: currentFrame.width, height: fittingSize.height)
        panel.setFrame(newFrame, display: true, animate: true)
        panel.invalidateShadow()
    }

    private func getPopoverPanel() -> NSPanel? {
        for window in NSApp.windows {
            if let panel = window as? NSPanel,
               panel.identifier == NSUserInterfaceItemIdentifier("remarc.popover"),
               panel.isVisible {
                return panel
            }
        }
        return nil
    }

}

// MARK: - Dim Overlay Content View

/// Custom NSView that draws a rounded dim rectangle and forwards clicks to dismiss the editor.
/// Direct mouseDown handling is more reliable than NSEvent monitors for .nonactivatingPanel windows.
private class DimOverlayContentView: NSView {
    var onMouseDown: (() -> Void)?
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

// MARK: - Floating Editor Wrapper

struct FloatingEditorWrapper: View {
    @State private var text: String
    @State private var attachments: [String]

    let presentationGeneration: UInt64
    let screenshotImagePath: String?
    let referenceText: String?
    let comment: Comment?
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    init(presentationGeneration: UInt64, initialText: String, initialAttachments: [String], screenshotImagePath: String?, referenceText: String?, comment: Comment?, onSave: @escaping (String, [String]) -> Void, onCancel: @escaping () -> Void) {
        self.presentationGeneration = presentationGeneration
        _text = State(initialValue: initialText)
        _attachments = State(initialValue: initialAttachments)
        self.screenshotImagePath = screenshotImagePath
        self.referenceText = referenceText
        self.comment = comment
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        CommentEditorView(
            commentText: $text,
            attachments: $attachments,
            screenshotImagePath: screenshotImagePath,
            referenceText: referenceText,
            comment: comment,
            presentationGeneration: presentationGeneration,
            onSave: onSave,
            onCancel: onCancel
        )
        .frame(width: AppConstants.editorWidth)
        // Material background and shadow provided by NSVisualEffectView + maskImage
        // in FloatingEditorController — no SwiftUI material backgrounds here.
        .onChange(of: text) { _, newValue in
            let controller = FloatingEditorController.shared
            guard controller.isCurrentPresentation(presentationGeneration) else { return }
            controller.currentText = newValue
        }
        .onChange(of: attachments) { _, newValue in
            let controller = FloatingEditorController.shared
            guard controller.isCurrentPresentation(presentationGeneration) else { return }
            controller.currentAttachments = newValue
        }
    }
}
