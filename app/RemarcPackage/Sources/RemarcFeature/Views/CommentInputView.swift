import SwiftUI
import UniformTypeIdentifiers

struct CommentInputView: View {
    @EnvironmentObject var controller: CommentInputController
    @Environment(\.colorScheme) private var colorScheme
    /// Observed so an already-open composer reacts when wake availability
    /// changes (plugin installed or removed) instead of showing stale state.
    @ObservedObject private var settings = SettingsManager.shared
    @State private var commentText: String = ""
    @State private var attachments: [String] = []
    @State private var isCloseHovered = false
    @State private var isSaveHovered = false
    @State private var isAttachHovered = false
    @State private var isMicHovered = false
    @State private var isTextScrollable = false
    @State private var suppressTextCancelAutoSave = false
    @FocusState private var isFocused: Bool

    private let textMaxHeight: CGFloat = 300

    var body: some View {
        ZStack(alignment: .topTrailing) {
        VStack(spacing: 0) {
            // Source reference line
            headerSection

            if isTextScrollable { Divider() }

            // Text input
            CommentTextEditor(
                text: $commentText,
                onSubmit: { controller.saveComment(text: commentText, attachments: attachments) },
                onCancel: {
                    if controller.autoSaveCountdownActive {
                        controller.cancelAutoSave()
                    } else {
                        controller.dismiss()
                    }
                },
                onImagePaste: { image in
                    if let path = PersistenceManager.shared.saveAttachmentImage(image) {
                        attachments.append(path)
                    }
                },
                onContentHeightChange: { height in
                    let scrollable = height > textMaxHeight
                    if scrollable != isTextScrollable {
                        isTextScrollable = scrollable
                    }
                }
            )
            .focused($isFocused)
            .frame(minHeight: 40, maxHeight: textMaxHeight)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if isTextScrollable { Divider() }

            // Footer
            HStack(alignment: .center) {
                SessionPickerPill(
                    selectedSessionID: $controller.targetSessionID,
                    mode: .create,
                    comment: nil
                )

                Button(action: pickAttachmentImage) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(isAttachHovered ? 0.6 : 0.3))
                }
                .buttonStyle(.plain)
                .onHover { hovering in isAttachHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isAttachHovered)
                .help("Attach image")

                if #available(macOS 26, *) {
                    VoiceMicButton(
                        isMicHovered: $isMicHovered,
                        appendText: appendTranscribedText,
                        transcriptionGeneration: controller.currentDraftGeneration,
                        acceptsTranscription: { controller.isCurrentDraft($0) }
                    )
                }

                Spacer()

                // Sits left of Save: it is the less-common action, and reading
                // left-to-right the pair goes "send now" then "save".
                // Pre-armed by the wake screenshot shortcut, Save already wakes,
                // so a second control promising the same thing would confuse.
                // Keyed to the session picker's current choice, not to "is any
                // agent awake": wake reaches only the agent paired with this
                // session, so anywhere else the button would promise an
                // interruption that never happens.
                if settings.wakeAvailable(for: controller.targetSessionID) && !controller.wakeOnSave {
                    WakeButton(colorScheme: colorScheme) {
                        controller.saveComment(
                            text: commentText,
                            attachments: attachments,
                            wakeRequested: true
                        )
                    }
                }

                // Save / Recording button
                if #available(macOS 26, *) {
                    VoiceAwareSaveButton(
                        isSaveHovered: $isSaveHovered,
                        colorScheme: colorScheme,
                        onSave: { controller.saveComment(text: commentText, attachments: attachments) },
                        appendText: appendTranscribedText,
                        transcriptionGeneration: controller.currentDraftGeneration,
                        acceptsTranscription: { controller.isCurrentDraft($0) },
                        autoSaveState: voiceAutoSaveButtonState
                    )
                } else {
                    saveButton
                }

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        .overlay {
            if #available(macOS 26, *) {
                VoiceRecordingBorder(colorScheme: colorScheme)
            }
        }

            // Close button
            Button(action: { controller.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCloseHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in isCloseHovered = hovering }
            .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remarc.commentInput")
        .onAppear {
            commentText = ""
            attachments = []
            isFocused = true
        }
        .onChange(of: controller.textResetToken) {
            if #available(macOS 26, *), VoiceInputService.shared.state != .idle {
                VoiceInputService.shared.cancelRecording()
            }
            commentText = ""
            attachments = []
            isFocused = true
        }
        .onChange(of: commentText) {
            controller.currentText = commentText
            if controller.autoSaveCountdownActive && !suppressTextCancelAutoSave {
                controller.cancelAutoSave()
            }
        }
        .onChange(of: attachments) {
            controller.currentAttachments = attachments
        }
        .onChange(of: controller.validationFeedbackTrigger) { _, trigger in
            guard trigger > 0 else { return }
            refocusEditor()
        }
        .onChange(of: controller.pendingVoiceText) {
            if let text = controller.pendingVoiceText, !text.isEmpty {
                // Suppress auto-save cancellation for this programmatic text change
                suppressTextCancelAutoSave = true
                appendTranscribedText(text)
                controller.pendingVoiceText = nil
                controller.currentText = commentText
                // Start auto-save countdown after voice transcription completes
                if #available(macOS 26, *), VoiceInputService.shared.state == .idle {
                    controller.startAutoSaveCountdown()
                }
                // Re-enable after a brief delay so the batched onChange(of: commentText) is skipped
                DispatchQueue.main.async {
                    suppressTextCancelAutoSave = false
                }
            }
        }
    }

    @available(macOS 26, *)
    private var voiceAutoSaveButtonState: VoiceAutoSaveButtonState {
        VoiceAutoSaveButtonState(
            countdownActive: controller.autoSaveCountdownActive,
            progress: controller.autoSaveProgress,
            remainingSeconds: controller.autoSaveRemainingSeconds,
            feedbackTrigger: controller.saveFeedbackTrigger,
            onHoverChanged: { controller.isSaveButtonHovered = $0 }
        )
    }

    // MARK: - Save Button (fallback for pre-macOS 26)

    private var saveButton: some View {
        Button(action: { controller.saveComment(text: commentText, attachments: attachments) }) {
            HStack(spacing: 6) {
                Text("Save")
                    .font(.system(size: 12, weight: .medium))
                Text("⌘↵")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Color.remarcBrandGradient(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .opacity(isSaveHovered ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isSaveHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
        .modifier(SaveButtonFeedbackModifier(trigger: controller.saveFeedbackTrigger))
        .accessibilityIdentifier("remarc.commentInput.submitButton")
    }

    private func refocusEditor() {
        isFocused = false
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    // MARK: - Header

    /// Same precedence rule `saveComment` uses (`WebContextAttachmentPolicy`),
    /// so the badge shown while composing never disagrees with what actually
    /// gets saved. Deliberately not `.filtered()`'d, unlike the save path: this
    /// mirrors the pre-existing behavior of this property (it never filtered
    /// either), and filtering is a user-visible change beyond unifying which
    /// context wins - out of scope here.
    private var activeWebContext: WebContext? {
        let isChromium = controller.currentSelection?.appBundleID
            .flatMap { AppConstants.chromiumBundleIDs.contains($0) } ?? false
        return WebContextAttachmentPolicy.resolve(
            isChromium: isChromium,
            liveChromeContext: WebSocketService.shared.pendingWebContext,
            elementContext: controller.pendingElementWebContext,
            externalPageContext: controller.pendingExternalPageContext
        )
    }

    private var activeRegionElements: [WebContext]? {
        WebSocketService.shared.pendingRegionElements
    }

    private var activeScreenshotWebContext: WebContext? {
        guard controller.shouldAttachWebContextToCurrentScreenshot else { return nil }
        // Not routed through activeWebContext: screenshot drafts never carry a
        // TextSelection (showForScreenshot's beginDraft call never passes
        // `selection`), so activeWebContext's isChromium gate - derived from
        // controller.currentSelection - would always read false here and hide
        // context that is meant to show. Screenshot web context is already
        // gated upstream, at query time, by
        // ScreenshotWebContextPolicy.allowsWebContext(sourceBundleID:) in
        // showForScreenshot, so pendingWebContext being set here already
        // implies an allowed Chromium source - no additional gating needed at
        // display time. pendingExternalPageContext is not consulted either:
        // PopClip never triggers screenshot mode.
        return controller.pendingElementWebContext ?? WebSocketService.shared.pendingWebContext
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = controller.currentSelection {
                if let wc = activeWebContext {
                    HStack(spacing: 6) {
                        WebContextBadge(webContext: wc, regionElements: activeRegionElements, colorScheme: colorScheme)
                        if let hfCtx = wc.hyperframesContext, !hfCtx.isEmpty {
                            HyperframesContextBadge(hyperframesContext: hfCtx, colorScheme: colorScheme)
                        }
                    }
                }
                Text("\u{201C}\(selection.text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                    .font(.system(size: 12.5))
                    .italic()
                    .foregroundStyle(Color.remarcAccent(for: colorScheme))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .quoteBorder()
            } else if let elementContext = controller.pendingElementWebContext {
                let elementLabel = WebContext.smartLabel(
                    componentName: elementContext.componentName,
                    elementName: elementContext.elementName
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("Web Element", systemImage: "globe")
                            .font(.system(size: 11))
                            .labelStyle(TypeLabelStyle(colorScheme: colorScheme))
                        WebContextBadge(webContext: elementContext, regionElements: activeRegionElements, colorScheme: colorScheme)
                        if let hfCtx = elementContext.hyperframesContext, !hfCtx.isEmpty {
                            HyperframesContextBadge(hyperframesContext: hfCtx, colorScheme: colorScheme)
                        }
                    }
                    if let elementLabel {
                        Text(elementLabel)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.leading, 8)
                            .quoteBorder()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if controller.isScreenshotMode {
                if let wc = activeScreenshotWebContext {
                    HStack(spacing: 6) {
                        WebContextBadge(webContext: wc, regionElements: activeRegionElements, colorScheme: colorScheme)
                        if let hfCtx = wc.hyperframesContext, !hfCtx.isEmpty {
                            HyperframesContextBadge(hyperframesContext: hfCtx, colorScheme: colorScheme)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.45))
                    Text("Screenshot")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quoteBorder()
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.6))
                    Text("Quick Note")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.6))
                }
            }

            if !attachments.isEmpty {
                AttachmentStripView(attachments: attachments, isEditable: true) { index in
                    attachments.remove(at: index)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, attachments.isEmpty ? 10 : 2)
    }

    // MARK: - Helpers

    private func appendTranscribedText(_ text: String) {
        appendVoiceText(text, to: &commentText)
    }

    private func pickAttachmentImage() {
        controller.suppressClickOutside = true
        controller.orderOutForSystemDialog()
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let response = panel.runModal()

        controller.orderFrontAfterSystemDialog()
        controller.suppressClickOutside = false

        guard response == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            if let path = PersistenceManager.shared.saveAttachmentImage(image) {
                attachments.append(path)
            }
        }
    }
}

// MARK: - Tooltip Shape

/// Rounded rectangle with a small arrow pointer on one edge.
/// Used in screenshot mode to point at the selected region.
private struct TooltipShape: Shape {
    let cornerRadius: CGFloat
    let arrowEdge: Edge
    let arrowWidth: CGFloat
    let arrowDepth: CGFloat

    init(cornerRadius: CGFloat, arrowEdge: Edge, arrowWidth: CGFloat = 14, arrowDepth: CGFloat = 7) {
        self.cornerRadius = cornerRadius
        self.arrowEdge = arrowEdge
        self.arrowWidth = arrowWidth
        self.arrowDepth = arrowDepth
    }

    func path(in rect: CGRect) -> Path {
        let cr = cornerRadius
        let halfArrow = arrowWidth / 2
        let tipR: CGFloat = 1.5

        // Body rect (main rounded rectangle, excluding arrow space)
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

        var path = Path()

        // Start on top edge after top-left corner
        path.move(to: CGPoint(x: body.minX + cr, y: body.minY))

        // -- Top edge --
        if arrowEdge == .top {
            let mid = body.midX
            path.addLine(to: CGPoint(x: mid - halfArrow, y: body.minY))
            path.addCurve(to: CGPoint(x: mid, y: rect.minY),
                         control1: CGPoint(x: mid - halfArrow * 0.3, y: body.minY),
                         control2: CGPoint(x: mid - tipR, y: rect.minY))
            path.addCurve(to: CGPoint(x: mid + halfArrow, y: body.minY),
                         control1: CGPoint(x: mid + tipR, y: rect.minY),
                         control2: CGPoint(x: mid + halfArrow * 0.3, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.maxX - cr, y: body.minY))

        // Top-right corner
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                   tangent2End: CGPoint(x: body.maxX, y: body.minY + cr),
                   radius: cr)

        // -- Right edge --
        if arrowEdge == .trailing {
            let mid = body.midY
            path.addLine(to: CGPoint(x: body.maxX, y: mid - halfArrow))
            path.addCurve(to: CGPoint(x: rect.maxX, y: mid),
                         control1: CGPoint(x: body.maxX, y: mid - halfArrow * 0.3),
                         control2: CGPoint(x: rect.maxX, y: mid - tipR))
            path.addCurve(to: CGPoint(x: body.maxX, y: mid + halfArrow),
                         control1: CGPoint(x: rect.maxX, y: mid + tipR),
                         control2: CGPoint(x: body.maxX, y: mid + halfArrow * 0.3))
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - cr))

        // Bottom-right corner
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                   tangent2End: CGPoint(x: body.maxX - cr, y: body.maxY),
                   radius: cr)

        // -- Bottom edge --
        if arrowEdge == .bottom {
            let mid = body.midX
            path.addLine(to: CGPoint(x: mid + halfArrow, y: body.maxY))
            path.addCurve(to: CGPoint(x: mid, y: rect.maxY),
                         control1: CGPoint(x: mid + halfArrow * 0.3, y: body.maxY),
                         control2: CGPoint(x: mid + tipR, y: rect.maxY))
            path.addCurve(to: CGPoint(x: mid - halfArrow, y: body.maxY),
                         control1: CGPoint(x: mid - tipR, y: rect.maxY),
                         control2: CGPoint(x: mid - halfArrow * 0.3, y: body.maxY))
        }
        path.addLine(to: CGPoint(x: body.minX + cr, y: body.maxY))

        // Bottom-left corner
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                   tangent2End: CGPoint(x: body.minX, y: body.maxY - cr),
                   radius: cr)

        // -- Left edge --
        if arrowEdge == .leading {
            let mid = body.midY
            path.addLine(to: CGPoint(x: body.minX, y: mid + halfArrow))
            path.addCurve(to: CGPoint(x: rect.minX, y: mid),
                         control1: CGPoint(x: body.minX, y: mid + halfArrow * 0.3),
                         control2: CGPoint(x: rect.minX, y: mid + tipR))
            path.addCurve(to: CGPoint(x: body.minX, y: mid - halfArrow),
                         control1: CGPoint(x: rect.minX, y: mid - tipR),
                         control2: CGPoint(x: body.minX, y: mid - halfArrow * 0.3))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + cr))

        // Top-left corner (close)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                   tangent2End: CGPoint(x: body.minX + cr, y: body.minY),
                   radius: cr)

        path.closeSubpath()
        return path
    }
}
