import SwiftUI

/// Reusable callout/alert view with semantic styles.
///
/// Usage:
/// ```
/// CalloutView(.info, "Model will download on first use.")
/// CalloutView(.error, "Download failed: \(message)")
/// CalloutView(.warning, "Large model requires 1 GB of disk space.")
/// ```
struct CalloutView: View {
    enum Style {
        case info
        case warning
        case error

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        func tint(for colorScheme: ColorScheme) -> Color {
            switch self {
            case .info: return Color.remarcInfo(for: colorScheme)
            case .warning: return Color.remarcWarning(for: colorScheme)
            case .error: return Color.remarcError(for: colorScheme)
            }
        }

        func background(for colorScheme: ColorScheme) -> Color {
            tint(for: colorScheme).opacity(0.08)
        }

        func border(for colorScheme: ColorScheme) -> Color {
            tint(for: colorScheme).opacity(0.2)
        }
    }

    let style: Style
    let text: String
    let actionLabel: String?
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(_ style: Style, _ text: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.style = style
        self.text = text
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: style.icon)
                .font(.system(size: 11))
                .foregroundStyle(style.tint(for: colorScheme))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    Button(action: action) {
                        Text(actionLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(style.tint(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(style.background(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style.border(for: colorScheme))
                )
        )
    }
}
