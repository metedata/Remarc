import SwiftUI

struct ConfirmationButton: View {
    enum Role {
        case cancel
        case destructive
        case confirm
    }

    let label: String
    let role: Role
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: role == .cancel ? 1 : 0)

                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var foregroundColor: Color {
        switch role {
        case .cancel:
            .primary
        case .destructive, .confirm:
            .white
        }
    }

    private var background: some ShapeStyle {
        switch role {
        case .cancel:
            AnyShapeStyle(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        case .destructive:
            AnyShapeStyle(
                Color.remarcError(for: colorScheme)
                    .opacity(isHovered ? 0.85 : 1.0)
            )
        case .confirm:
            AnyShapeStyle(
                Color(red: 0.133, green: 0.545, blue: 0.408) // #228B68 — darker green for white text contrast
                    .opacity(isHovered ? 0.85 : 1.0)
            )
        }
    }

    private var borderColor: Color {
        switch role {
        case .cancel:
            .primary.opacity(isHovered ? 0.25 : 0.15)
        case .destructive, .confirm:
            .clear
        }
    }
}
