import SwiftUI

struct HistoryCardView: View {
    let comment: Comment
    let onRestore: () -> Void
    let onPermanentDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false
    @Environment(\.colorScheme) private var colorScheme

    private var showActions: Bool { isHovered || showDeleteConfirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            referenceView
            if !comment.attachments.isEmpty {
                AttachmentStripView(attachments: comment.attachments, commentText: Comment.normalizedCommentText(comment.commentText), isEditable: false, maxThumbnailWidth: 140, maxThumbnailHeight: 80)
                    .padding(.leading, 8)
                    .quoteBorder()
            }
            if let commentText = comment.meaningfulCommentText {
                commentTextView(commentText)
            }
            metadataView
        }
        .padding(12)
        .modifier(CardSurfaceModifier(isHovered: isHovered))
        .opacity(0.85)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }

    // MARK: - Reference

    @ViewBuilder
    private var referenceView: some View {
        // Type label — consistent across all types
        HStack(spacing: 6) {
            Label(comment.type.displayName, systemImage: comment.type.iconName)
                .font(.system(size: 11))
                .labelStyle(TypeLabelStyle(colorScheme: colorScheme))
            if comment.webContext != nil {
                WebContextBadge(webContext: comment.webContext!, regionElements: comment.regionElements, colorScheme: colorScheme)
            }
            if let hfCtx = comment.webContext?.hyperframesContext, !hfCtx.isEmpty {
                HyperframesContextBadge(hyperframesContext: hfCtx, colorScheme: colorScheme)
            }
        }

        // Type-specific content below the label
        switch comment.type {
        case .comment(let text):
            Text("\u{201C}\(text)\u{201D}")
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(Color.remarcAccent(for: colorScheme))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .quoteBorder()

        case .screenshot(let imagePath):
            ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 140, maxHeight: 80)
                .padding(.leading, 8)
                .quoteBorder()
                // The fourth preview entry point. CommentCardView, CommentEditorView,
                // and AttachmentStripView already open it; this one was missing, so a
                // history screenshot could not be opened at all.
                .contentShape(Rectangle())
                .onTapGesture {
                    ScreenshotPreviewController.shared.show(
                        imagePath: imagePath,
                        commentText: Comment.normalizedCommentText(comment.commentText)
                    )
                }

        case .webElement(let name, let path):
            let displayName = WebContext.smartLabel(
                componentName: name,
                elementName: comment.webContext?.elementName
            )
            WebElementReferenceView(name: displayName, path: path, colorScheme: colorScheme)

        case .quickNote, .critMode:
            EmptyView()
        }
    }

    // MARK: - Comment Text

    private func commentTextView(_ commentText: String) -> some View {
        Text(commentText)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Metadata + Restore

    private var metadataView: some View {
        HStack(spacing: 4) {
            if let deletedAt = comment.deletedAt {
                Text({
                    let date = "Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))"
                    if let app = appDisplayName(for: comment) {
                        return "\(date) \u{00B7} \(app)"
                    }
                    return date
                }())
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
            } else if let app = appDisplayName(for: comment) {
                Text(app)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                CardActionButton(icon: "arrow.uturn.backward", tooltip: "Restore", tint: Color.remarcPrimary(for: colorScheme), action: onRestore)
                CardActionButton(icon: "trash", tooltip: "Delete permanently", tint: Color.remarcError(for: colorScheme)) {
                    showDeleteConfirmation = true
                }
                .popover(isPresented: $showDeleteConfirmation, arrowEdge: .bottom) {
                    VStack(spacing: 8) {
                        Text("Delete permanently?")
                            .font(.system(size: 12, weight: .medium))
                        if comment.type.imagePath != nil || !comment.attachments.isEmpty {
                            Text("This cannot be undone. Image references in exports may break.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("This cannot be undone.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                        }
                        HStack(spacing: 8) {
                            ConfirmationButton(label: "Cancel", role: .cancel) {
                                showDeleteConfirmation = false
                            }
                            ConfirmationButton(label: "Delete", role: .destructive) {
                                showDeleteConfirmation = false
                                onPermanentDelete()
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .opacity(showActions ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: showActions)
        }
    }
}
