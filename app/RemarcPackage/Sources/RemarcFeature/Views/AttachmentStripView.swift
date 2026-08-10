import SwiftUI
import AppKit

struct AttachmentStripView: View {
    let attachments: [String]
    var commentText: String? = nil
    var isEditable: Bool = true
    var maxThumbnailWidth: CGFloat = 140
    var maxThumbnailHeight: CGFloat = 100
    var onRemove: ((Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, path in
                    attachmentThumbnail(path: path, index: index)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, isEditable ? 4 : 0)
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(path: String, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            ScreenshotThumbnailView(imagePath: path, maxWidth: maxThumbnailWidth, maxHeight: maxThumbnailHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    ScreenshotPreviewController.shared.show(imagePath: path, commentText: commentText)
                }
                .contextMenu {
                    Button {
                        if let nsImage = loadScreenshotImage(path) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.writeObjects([nsImage])
                            ToastManager.shared.show("Image copied")
                        }
                    } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    }

                    Button {
                        saveAttachmentAs(imagePath: path)
                    } label: {
                        Label("Save Image As\u{2026}", systemImage: "square.and.arrow.down")
                    }
                }

            if isEditable {
                Button {
                    onRemove?(index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
    }

    private func saveAttachmentAs(imagePath: String) {
        let sourceURL = resolveImagePath(imagePath)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = sourceURL.lastPathComponent
        savePanel.canCreateDirectories = true
        savePanel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 4)

        savePanel.begin { response in
            guard response == .OK, let destinationURL = savePanel.url else { return }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                Task { @MainActor in
                    ToastManager.shared.show("Image saved")
                }
            } catch {
                debugLog("Failed to save attachment: \(error.localizedDescription)")
                Task { @MainActor in
                    ToastManager.shared.show("Failed to save image")
                }
            }
        }
    }
}
