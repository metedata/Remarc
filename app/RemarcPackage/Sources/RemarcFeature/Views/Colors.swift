import AppKit
import SwiftUI

extension NSColor {
    /// Brand indigo for AppKit drawing contexts (matches `Color.remarcBrandIndigo`).
    static let remarcBrandIndigo = NSColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 1.0)
}

extension Color {

    // MARK: - Brand

    public static func remarcPrimary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.647, green: 0.706, blue: 0.988)   // #A5B4FC
            : Color(red: 0.263, green: 0.220, blue: 0.792)   // #4338CA  indigo-700
    }

    public static func remarcSecondary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.624, green: 0.627, blue: 0.753)   // #9FA0C0
            : Color(red: 0.459, green: 0.467, blue: 0.627)   // #7577A0
    }

    public static func remarcAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.769, green: 0.710, blue: 0.992)   // #C4B5FD
            : Color(red: 0.545, green: 0.361, blue: 0.965)   // #8B5CF6
    }

    // MARK: - Status

    public static func remarcSuccess(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.239, green: 0.859, blue: 0.651)   // #3DDBA6
            : Color(red: 0.051, green: 0.576, blue: 0.451)   // #0D9373
    }

    public static func remarcWarning(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.949, green: 0.663, blue: 0.294)   // #F2A94B
            : Color(red: 0.690, green: 0.424, blue: 0.094)   // #B06C18
    }

    public static func remarcError(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.973, green: 0.443, blue: 0.443)   // #F87171
            : Color(red: 0.863, green: 0.149, blue: 0.149)   // #DC2626
    }

    public static func remarcInfo(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.220, green: 0.741, blue: 0.973)   // #38BDF8
            : Color(red: 0.008, green: 0.518, blue: 0.780)   // #0284C7
    }

    // MARK: - Raw Brand Tints (for audio-reactive effects, gradients, etc.)

    /// Raw brand indigo — use `remarcPrimary` for standard UI elements.
    public static let remarcBrandIndigo = Color(red: 0.388, green: 0.400, blue: 0.945)  // #6366F1
    /// Raw brand violet — use `remarcAccent` for standard UI elements.
    public static let remarcBrandViolet = Color(red: 0.545, green: 0.361, blue: 0.965)  // #8B5CF6

    // MARK: - Harness Marks

    /// Anthropic's orange, for the Claude Code session badge only. Someone
    /// else's brand colour, so it is fixed rather than scheme-adaptive — and it
    /// belongs to no Remarc token, which is why it is not named like one.
    public static let claudeMarkOrange = Color(red: 0.886, green: 0.482, blue: 0.227)  // #E27B3A

    // MARK: - Surfaces

    public static func remarcDropdownBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
    }

    // MARK: - Gradients

    public static func remarcBrandGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [
                remarcPrimary(for: colorScheme),
                remarcPrimary(for: colorScheme).opacity(0.8)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Mid-tone indigo for high-contrast white-text buttons.
    /// Appearance-invariant: returns the same value for light and dark modes.
    public static func remarcButtonBase(for colorScheme: ColorScheme) -> Color {
        Color(red: 0.302, green: 0.275, blue: 0.835)              // #4D46D5  indigo-600
    }

    /// High-contrast gradient for buttons with white text.
    /// Appearance-invariant so white foreground text stays readable
    /// against tinted or dark backgrounds.
    public static func remarcButtonGradient(for colorScheme: ColorScheme) -> LinearGradient {
        let base = remarcButtonBase(for: colorScheme)
        return LinearGradient(
            colors: [
                base,
                base.opacity(0.85)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public static func remarcBorderGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.2 : 0.4),
                Color.white.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Edge Refraction

    /// Simulates light from a colored element refracting along a rounded card edge.
    /// Renders a trimmed, blurred stroke clipped inside the card shape, masked with a
    /// radial gradient so intensity falls off naturally from the source point.
    ///
    /// Usage:
    ///     .modifier(EdgeRefractionModifier(
    ///         color: statusColor,
    ///         corner: .topTrailing,
    ///         cornerRadius: 10
    ///     ))
    ///
    /// Parameters:
    ///   - color: The tint color of the glow (typically the color of the nearby element).
    ///   - corner: Which corner the light source is near.
    ///   - cornerRadius: Must match the card's corner radius.
    ///   - intensity: Multiplier for opacity (default 1.0). Use < 1 for subtler effect.
    ///   - spread: How far the glow extends along the edges (default 65pt).

    /// Layered elliptical gradient wash for popover backgrounds
    /// Indigo from top-left, violet from bottom-right, with .plusLighter blend
    @ViewBuilder
    public static func remarcBackgroundGradient(for colorScheme: ColorScheme) -> some View {
        let base = colorScheme == .dark ? Color.black.opacity(0.40) : Color.black.opacity(0.06)
        let op = colorScheme == .dark ? 0.18 : 0.13

        base
            .overlay(
                EllipticalGradient(
                    colors: [remarcBrandIndigo.opacity(op * 1.4), .clear],
                    center: .topLeading,
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 1.0
                )
                .blendMode(.plusLighter)
            )
            .overlay(
                EllipticalGradient(
                    colors: [remarcBrandViolet.opacity(op * 0.6), .clear],
                    center: .bottomTrailing,
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 0.7
                )
                .blendMode(.plusLighter)
            )
    }
}

// MARK: - Quote Border Modifier

/// 2pt indigo left border used on reference content (text quotes, screenshots, web elements, attachments).
/// Replaces the repeated `.overlay(alignment: .leading) { RoundedRectangle... }` pattern.
struct QuoteBorderModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                .frame(width: 2)
        }
    }
}

extension View {
    /// Adds a 2pt indigo left border. Use on reference content (quotes, screenshots, attachments).
    func quoteBorder() -> some View {
        modifier(QuoteBorderModifier())
    }
}

// MARK: - Edge Refraction Modifier

/// Renders a subtle colored glow along a card's rounded corner edge,
/// as if a nearby colored element is casting light that refracts along the border.
///
/// The effect uses a trimmed, blurred stroke of the card shape, clipped inward
/// and masked with a radial gradient so intensity falls off naturally from the corner.
struct EdgeRefractionModifier: ViewModifier {
    let color: Color
    let corner: UnitPoint
    let cornerRadius: CGFloat
    var intensity: CGFloat = 1.0
    var spread: CGFloat = 65

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let trim = trimRange(for: corner)
            let center = maskCenter(for: corner)
            let baseOpacity = colorScheme == .dark ? 0.5 : 0.55

            shape
                .trim(from: trim.from, to: trim.to)
                .stroke(color.opacity(baseOpacity * intensity), lineWidth: 1.5)
                .blur(radius: 2.5)
                .clipShape(shape)
                .mask(
                    RadialGradient(
                        colors: [.white, .white.opacity(0.3), .clear],
                        center: center,
                        startRadius: 0,
                        endRadius: spread
                    )
                )
                .allowsHitTesting(false)
        }
    }

    /// Trim ranges for each corner.
    /// RoundedRectangle path starts at mid-right, goes clockwise.
    private func trimRange(for corner: UnitPoint) -> (from: CGFloat, to: CGFloat) {
        switch corner {
        case .topTrailing:  return (from: 0.82, to: 1.0)
        case .bottomTrailing: return (from: 0.0, to: 0.18)
        case .bottomLeading: return (from: 0.25, to: 0.43)
        case .topLeading:   return (from: 0.57, to: 0.75)
        default:            return (from: 0.82, to: 1.0)
        }
    }

    /// Mask gradient center for each corner, slightly inset from the actual corner.
    private func maskCenter(for corner: UnitPoint) -> UnitPoint {
        switch corner {
        case .topTrailing:    return UnitPoint(x: 0.96, y: 0.08)
        case .bottomTrailing: return UnitPoint(x: 0.96, y: 0.92)
        case .bottomLeading:  return UnitPoint(x: 0.04, y: 0.92)
        case .topLeading:     return UnitPoint(x: 0.04, y: 0.08)
        default:              return UnitPoint(x: 0.96, y: 0.08)
        }
    }
}
