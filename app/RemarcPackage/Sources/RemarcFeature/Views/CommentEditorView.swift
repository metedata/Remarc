import SwiftUI
import UniformTypeIdentifiers

struct CommentEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var floatingController = FloatingEditorController.shared
    @Binding var commentText: String
    @Binding var attachments: [String]
    @FocusState private var isFocused: Bool
    @State private var isCloseHovered = false
    @State private var isSaveHovered = false
    @State private var isAttachHovered = false
    @State private var isMicHovered = false
    @State private var editorSessionID: UUID?
    @State private var suppressTextCancelAutoSave = false

    let screenshotImagePath: String?
    let referenceText: String?
    let comment: Comment?
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                // Reference (read-only)
                if let imagePath = screenshotImagePath {
                    ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 200)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .quoteBorder()
                        .onTapGesture {
                            ScreenshotPreviewController.shared.show(imagePath: imagePath, commentText: nil)
                        }
                } else if let ref = referenceText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\u{201C}\(ref)\u{201D}")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(Color.remarcAccent(for: colorScheme))
                            .lineLimit(10)
                            .padding(.leading, 8)
                            .padding(.trailing, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .quoteBorder()
                        if let comment {
                            HStack(spacing: 4) {
                                Text({
                                    let date = comment.createdAt.formatted(date: .abbreviated, time: .shortened)
                                    if let app = appDisplayName(for: comment) {
                                        return "\(app) — \(date)"
                                    }
                                    return date
                                }())
                                    .font(.system(size: 10))
                                    .foregroundStyle(.primary.opacity(0.45))
                                    .lineLimit(1)
                                Text(comment.shortID)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.4))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                } else {
                    Label("Quick Note", systemImage: "note.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Attachment strip (above text editor)
                if !attachments.isEmpty {
                    AttachmentStripView(attachments: attachments, isEditable: true) { index in
                        attachments.remove(at: index)
                    }
                }

                // Text editor
                CommentTextEditor(
                    text: $commentText,
                    onSubmit: { onSave(commentText, attachments) },
                    onCancel: onCancel,
                    onImagePaste: { image in
                        if let path = PersistenceManager.shared.saveAttachmentImage(image) {
                            attachments.append(path)
                        }
                    },
                )
                .focused($isFocused)
                .frame(minHeight: 30, maxHeight: 300)
                .clipped()

                // Footer
                HStack {
                    SessionPickerPill(
                        selectedSessionID: $editorSessionID,
                        mode: comment != nil ? .edit : .create,
                        comment: comment
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
                        VoiceMicButton(isMicHovered: $isMicHovered, appendText: appendTranscribedText)
                    }

                    Spacer()

                    if #available(macOS 26, *) {
                        VoiceAwareSaveButton(
                            isSaveHovered: $isSaveHovered,
                            colorScheme: colorScheme,
                            onSave: { onSave(commentText, attachments) },
                            appendText: appendTranscribedText,
                            autoSaveState: voiceAutoSaveButtonState
                        )
                    } else {
                        Button(action: { onSave(commentText, attachments) }) {
                            HStack(spacing: 6) {
                                Text("Save")
                                    .font(.system(size: 12, weight: .medium))
                                HStack(spacing: 1) {
                                    Image(systemName: "command")
                                    Image(systemName: "return")
                                }
                                .font(.system(size: 10, weight: .medium))
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
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Close button
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCloseHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in isCloseHovered = hovering }
            .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .overlay {
            if #available(macOS 26, *) {
                VoiceRecordingBorder(colorScheme: colorScheme)
            }
        }
        .onAppear {
            isFocused = true
            editorSessionID = comment?.sessionID ?? FloatingEditorController.shared.targetSessionID
        }
        .onChange(of: editorSessionID) { _, newValue in
            if comment == nil {
                FloatingEditorController.shared.targetSessionID = newValue
            }
        }
        .onChange(of: commentText) { _, newValue in
            floatingController.currentText = newValue
            if floatingController.autoSaveCountdownActive && !suppressTextCancelAutoSave {
                floatingController.cancelAutoSave()
            }
        }
        .onChange(of: floatingController.pendingVoiceText) { _, text in
            guard let text, !text.isEmpty else { return }
            suppressTextCancelAutoSave = true
            appendTranscribedText(text)
            floatingController.pendingVoiceText = nil
            floatingController.currentText = commentText
            if #available(macOS 26, *), VoiceInputService.shared.state == .idle {
                floatingController.startAutoSaveCountdown()
            }
            DispatchQueue.main.async {
                suppressTextCancelAutoSave = false
            }
        }
    }

    private func appendTranscribedText(_ text: String) {
        appendVoiceText(text, to: &commentText)
    }

    @available(macOS 26, *)
    private var voiceAutoSaveButtonState: VoiceAutoSaveButtonState {
        VoiceAutoSaveButtonState(
            countdownActive: floatingController.autoSaveCountdownActive,
            progress: floatingController.autoSaveProgress,
            remainingSeconds: floatingController.autoSaveRemainingSeconds,
            shake: floatingController.shakeAutoSave,
            onHoverChanged: { floatingController.isSaveButtonHovered = $0 },
            onPressed: floatingController.cancelAutoSaveCountdown
        )
    }

    private func pickAttachmentImage() {
        FloatingEditorController.shared.suppressClickOutside = true
        MenuBarPopoverController.shared.preventDismiss = true

        // Temporarily hide editor panels so the system file picker appears unobstructed.
        // NSOpenPanel runs out-of-process and its z-level cannot be controlled by the host app.
        FloatingEditorController.shared.orderOutForSystemDialog()

        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let response = panel.runModal()

        // Re-show editor panels and restore state
        FloatingEditorController.shared.orderFrontAfterSystemDialog()
        FloatingEditorController.shared.suppressClickOutside = false
        MenuBarPopoverController.shared.preventDismiss = false

        guard response == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            if let path = PersistenceManager.shared.saveAttachmentImage(image) {
                attachments.append(path)
            }
        }
    }
}
