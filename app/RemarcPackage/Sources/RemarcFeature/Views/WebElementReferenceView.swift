import SwiftUI

/// Shared view for rendering a web element reference (component name + file path)
/// with a 2pt indigo left border. Used by CommentCardView and HistoryCardView.
struct WebElementReferenceView: View {
    let name: String?
    let path: String?
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name {
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            if let path {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .quoteBorder()
    }
}
