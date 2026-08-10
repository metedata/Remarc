import SwiftUI
import AppKit

struct ScreenshotThumbnailView: View {
    let imagePath: String
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 200

    @Environment(\.colorScheme) private var colorScheme
    /// Runtime-only revision signal. Applying annotations replaces the PNG at the
    /// same path, and `NSImage(contentsOf:)` is lazy and caches by URL, so without
    /// this the thumbnail keeps showing the pre-annotation bytes.
    @ObservedObject private var revisions = StoredImageRevisionCenter.shared

    /// Reloads BYTES rather than handing the URL to NSImage, so the revision bump
    /// actually produces new pixels.
    private func loadCurrentImage() -> NSImage? {
        guard let data = try? Data(contentsOf: resolveImagePath(imagePath)) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        Group {
            if let nsImage = loadCurrentImage() {
                let imageSize = nsImage.size
                let scale = imageSize.width > 0 && imageSize.height > 0
                    ? min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1.0)
                    : 1.0
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(maxWidth: maxWidth)
                    .frame(height: 60)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.primary.opacity(0.25))
                    )
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
            }
        }
        // Reading the revision inside `body` is what subscribes this view to it.
        .id(revisions.revision(for: imagePath))
    }
}
