import SwiftUI

struct StatusDotView: View {
    let comment: Comment

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var anchorRef = AnchorViewRef()

    private var statusColor: Color {
        CommentStatus.color(for: comment.status, colorScheme: colorScheme)
    }

    private var isExpanded: Bool { isHovered || isOpen }
    private let dotCollapsedWidth: CGFloat = 15

    var body: some View {
        Button {
            if isOpen {
                DropdownPanelController.shared.dismiss()
            } else {
                showDropdown()
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(comment.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, isExpanded ? 6 : 4)
            .padding(.vertical, 3)
            .frame(width: isExpanded ? nil : dotCollapsedWidth, alignment: .leading)
            .clipShape(Capsule())
            .background(
                Capsule()
                    .fill(statusColor.opacity(isExpanded ? 0.12 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(statusColor.opacity(isExpanded ? 0.25 : 0), lineWidth: 0.5)
            )
            .background(alignment: .leading) {
                // Glow lives outside the clip so it can spread naturally.
                // Light mode uses reduced opacity — status colors are darker/more saturated.
                let glowPeak = colorScheme == .dark ? 0.5 : 0.25
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                statusColor.opacity(glowPeak),
                                statusColor.opacity(glowPeak * 0.4),
                                statusColor.opacity(glowPeak * 0.1),
                                statusColor.opacity(0),
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 14
                        )
                    )
                    .frame(width: 28, height: 28)
                    .offset(x: -6.5)
                    .opacity(isExpanded ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .overlay(DropdownAnchor(ref: anchorRef))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: comment.status)
        .help(comment.status == .resolved ? (comment.resolutionSummary ?? "Resolved") : "")
    }

    private func showDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        isOpen = true
        let cs = colorScheme
        let commentID = comment.id

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 130,
            colorScheme: cs,
            onDismiss: { isOpen = false }
        ) {
            StatusDropdownPanel(
                currentStatus: comment.status,
                colorScheme: cs
            ) { newStatus in
                PersistenceManager.shared.setCommentStatus(commentID, to: newStatus)
                DropdownPanelController.shared.dismiss()
            }
        }
    }
}

// MARK: - Dropdown Panel

private struct StatusDropdownPanel: View {
    let currentStatus: CommentStatus
    let colorScheme: ColorScheme
    let onSelect: (CommentStatus) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CommentStatus.allCases, id: \.self) { status in
                StatusOptionRow(
                    status: status,
                    isSelected: status == currentStatus,
                    colorScheme: colorScheme,
                    onSelect: { onSelect(status) }
                )
            }
        }
        .padding(5)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.remarcDropdownBackground(for: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct StatusOptionRow: View {
    let status: CommentStatus
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    @State private var isHovered = false

    private var dotColor: Color {
        CommentStatus.color(for: status, colorScheme: colorScheme)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isHovered {
            return Color.remarcPrimary(for: colorScheme).opacity(0.15)
        } else if isSelected {
            return Color.remarcPrimary(for: colorScheme).opacity(0.06)
        } else {
            return .clear
        }
    }
}
