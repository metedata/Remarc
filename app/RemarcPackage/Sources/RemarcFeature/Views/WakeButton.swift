import SwiftUI

/// Companion to Save: saves the comment and hands it straight to a running
/// Claude Code session instead of waiting for its next prompt.
///
/// A circular send button sitting left of Save, matched to Save's height so
/// the pair reads as one control group. It keeps its own colour because it
/// does something Save does not: an upward arrow, which is the send idiom
/// everywhere else.
public struct WakeButton: View {
    private let action: () -> Void
    private let colorScheme: ColorScheme

    @State private var isHovered = false
    @State private var isPressed = false

    public init(colorScheme: ColorScheme, action: @escaping () -> Void) {
        self.colorScheme = colorScheme
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                // Matches the Save button's height so the two sit on one line.
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(
                        colors: [
                            Color.remarcAccent(for: colorScheme),
                            Color.remarcAccent(for: colorScheme).opacity(0.82),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Circle()
                )
                .opacity(isPressed ? 0.75 : (isHovered ? 1.0 : 0.85))
                .scaleEffect(isPressed ? 0.95 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help("Send instantly & save")
        .accessibilityLabel("Send instantly and save")
        .accessibilityHint("Hands this comment to a running Claude Code session right away")
        .accessibilityIdentifier("remarc.commentInput.wakeButton")
    }
}
