import SwiftUI

// MARK: - Floating Action Button (used in Crit Mode recording view)

struct FloatingActionButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.remarcBrandGradient(for: colorScheme))
                        .shadow(
                            color: Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.4 : 0.25),
                            radius: isHovered ? 6 : 4,
                            y: isHovered ? 3 : 2
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.08 : 1.0))
        .opacity(isPressed ? 0.85 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
    }
}

// MARK: - Brand CTA Button Style

/// Shared button style for primary CTA buttons with brand gradient background.
/// Provides hover glow + subtle scale, press dim. Use with white foreground text.
///
/// Usage:
///     Button("Start Recording") { ... }
///         .buttonStyle(BrandCTAButtonStyle(colorScheme: colorScheme))
struct BrandCTAButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    var capsule: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background {
                Group {
                    if capsule {
                        Capsule()
                            .fill(Color.remarcBrandGradient(for: colorScheme))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.remarcBrandGradient(for: colorScheme))
                    }
                }
                .shadow(
                    color: Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.4 : 0),
                    radius: isHovered ? 8 : 0,
                    y: 0
                )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.03 : 1.0))
            .opacity(configuration.isPressed ? 0.85 : (isHovered ? 1.0 : 0.9))
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Creation Header Button (prominent circular buttons in the header)

struct CreationHeaderButton: View {
    let icon: String
    let brandColor: Color
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? brandColor : .primary.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(
                            Color.white.opacity(
                                colorScheme == .dark
                                    ? (isHovered ? 0.12 : 0.06)
                                    : (isHovered ? 0.65 : 0.45)
                            )
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(
                                colorScheme == .dark
                                    ? (isHovered ? 0.2 : 0.1)
                                    : (isHovered ? 0.8 : 0.6)
                            ),
                            lineWidth: 0.5
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
