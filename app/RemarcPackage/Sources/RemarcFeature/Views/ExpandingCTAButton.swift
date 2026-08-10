import SwiftUI

/// Compact capsule CTA that previews as a single symbol and expands on hover to reveal its label.
///
/// Use this for secondary actions that should stay quiet until the pointer is nearby:
/// destructive header actions, compact toolbar CTAs, and status-adjacent controls. The
/// collapsed state mirrors `StatusDotView`'s compact affordance; the expanded state uses
/// the same light capsule treatment as small settings CTAs such as `GetExtensionButton`.
struct ExpandingCTAButton: View {
    enum Role {
        case neutral
        case destructive
        case accent
    }

    let icon: String
    let title: String
    var role: Role = .neutral
    var help: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var tint: Color {
        switch role {
        case .neutral:
            return .primary
        case .destructive:
            return Color.remarcError(for: colorScheme)
        case .accent:
            return Color.remarcPrimary(for: colorScheme)
        }
    }

    private var isExpanded: Bool { isHovered && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: isExpanded ? 4 : 0) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 12, height: 12)

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isExpanded ? 1 : 0)
                    .frame(width: isExpanded ? nil : 0, alignment: .leading)
                    .clipped()
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, isExpanded ? 8 : 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(tint.opacity(isExpanded ? 0.10 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(isExpanded ? 0.18 : 0), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isEnabled)
    }

    private var foreground: Color {
        if !isEnabled { return .primary.opacity(0.2) }
        return isExpanded ? tint : .primary.opacity(0.45)
    }
}
