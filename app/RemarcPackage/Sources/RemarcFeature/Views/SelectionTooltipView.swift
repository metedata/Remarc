import SwiftUI

struct SelectionTooltipView: View {
    @ObservedObject var controller: SelectionTooltipWindowController
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            Task { @MainActor in
                if let selection = SelectionMonitor.shared.currentSelection {
                    CommentInputController.shared.showForSelection(selection)
                }
            }
        }) {
            HStack(spacing: 6) {
                // Remarc R logo in brand gradient circle
                ZStack {
                    Circle()
                        .fill(Color.remarcBrandIndigo)
                        .frame(width: 16, height: 16)
                    RemarcLogoShape(part: .outline)
                        .fill(.white)
                        .overlay {
                            RemarcLogoShape(part: .counter)
                                .fill(.black)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .frame(width: 8, height: 8)
                }
                Text("Comment")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .foregroundColor(.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            Capsule().fill(.regularMaterial)
                .overlay(
                    Capsule().fill(
                        Color.remarcPrimary(for: colorScheme)
                            .opacity(isHovered ? 0.15 : 0.06)
                    )
                )
        }
        .overlay(
            Capsule()
                .inset(by: 0.5)
                .stroke(
                    isHovered
                        ? Color.remarcPrimary(for: colorScheme).opacity(0.3)
                        : (colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)),
                    lineWidth: 0.5
                )
        )
        .fixedSize()
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .padding(6) // breathing room for shadow and scale effect
        .blur(radius: controller.isShowing ? 0 : 3)
        .scaleEffect(controller.isShowing ? 1 : 0.92)
        .opacity(controller.isShowing ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: controller.isShowing)
        .accessibilityIdentifier("remarc.tooltip")
    }
}
