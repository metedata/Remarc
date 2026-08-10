import SwiftUI

struct SessionPickerPill: View {
    @Binding var selectedSessionID: UUID?
    let mode: Mode
    let comment: Comment?

    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var isCreatingNew = false
    @State private var newSessionName = ""
    @State private var anchorRef = AnchorViewRef()
    @FocusState private var isTextFieldFocused: Bool

    enum Mode {
        /// Creating a new comment — pill selects target session
        case create
        /// Editing an existing comment — pill moves comment immediately
        case edit
    }

    private var selectedSession: Session? {
        persistence.activeSessions.first { $0.id == selectedSessionID }
    }

    private var displayName: String {
        selectedSession?.name ?? "Inbox"
    }

    var body: some View {
        if isCreatingNew {
            newSessionTextField
        } else {
            pillButton
        }
    }

    // MARK: - Pill Button

    private var pillButton: some View {
        Button {
            if isOpen {
                DropdownPanelController.shared.dismiss()
            } else {
                showDropdown()
            }
        } label: {
            HStack(spacing: 3) {
                Text(displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(chevronColor)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .overlay(DropdownAnchor(ref: anchorRef))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - New Session Text Field

    private var newSessionTextField: some View {
        TextField("Session name", text: $newSessionName)
            .font(.system(size: 11))
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.3), lineWidth: 0.5)
            )
            .frame(width: 100)
            .focused($isTextFieldFocused)
            .onSubmit {
                commitNewSession()
            }
            .onExitCommand {
                cancelNewSession()
            }
            .onChange(of: isTextFieldFocused) { _, focused in
                if !focused {
                    commitNewSession()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
    }

    // MARK: - Dropdown

    private func showDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        isOpen = true
        let cs = colorScheme
        let sessions = persistence.activeSessions
        let currentID = selectedSessionID

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            anchorWindowLevel: anchorRef.windowLevel(),
            onDismiss: { isOpen = false }
        ) {
            SessionDropdownPanel(
                sessions: sessions,
                currentSessionID: currentID,
                colorScheme: cs,
                onSelect: { sessionID in
                    selectSession(sessionID)
                    DropdownPanelController.shared.dismiss()
                },
                onNewSession: {
                    DropdownPanelController.shared.dismiss()
                    startCreatingNewSession()
                }
            )
        }
    }

    // MARK: - Actions

    private func selectSession(_ sessionID: UUID) {
        guard sessionID != selectedSessionID else { return }

        if mode == .edit, let comment {
            let previousSessionID = comment.sessionID
            let targetName = persistence.activeSessions.first { $0.id == sessionID }?.name ?? "Inbox"

            PersistenceManager.shared.moveComment(comment.id, to: sessionID)
            selectedSessionID = sessionID

            ToastManager.shared.show("Moved to \(targetName)", undo: {
                PersistenceManager.shared.moveComment(comment.id, to: previousSessionID)
            })
        } else {
            selectedSessionID = sessionID
        }
    }

    private func startCreatingNewSession() {
        newSessionName = ""
        isCreatingNew = true
    }

    private func commitNewSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelNewSession()
            return
        }

        if let session = PersistenceManager.shared.createSession(name: name) {
            selectSession(session.id)
            PersistenceManager.shared.setActiveSession(session.id)
        }
        isCreatingNew = false
        newSessionName = ""
    }

    private func cancelNewSession() {
        isCreatingNew = false
        newSessionName = ""
    }

    // MARK: - Colors

    private var textColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme)
        } else {
            return .primary.opacity(0.6)
        }
    }

    private var chevronColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme)
        } else if isHovered {
            return .primary.opacity(0.6)
        } else {
            return .primary.opacity(0.45)
        }
    }

    private var backgroundColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.12)
        } else if isHovered {
            return .primary.opacity(0.08)
        } else {
            return .primary.opacity(0.04)
        }
    }

    private var borderColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.3)
        } else if isHovered {
            return .primary.opacity(0.12)
        } else {
            return .primary.opacity(0.08)
        }
    }
}

// MARK: - Session Dropdown Panel

private struct SessionDropdownPanel: View {
    let sessions: [Session]
    let currentSessionID: UUID?
    let colorScheme: ColorScheme
    let onSelect: (UUID) -> Void
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionOptionRow(
                    name: session.name,
                    origin: session.origin,
                    isSelected: session.id == currentSessionID,
                    colorScheme: colorScheme,
                    onSelect: { onSelect(session.id) }
                )
            }

            Divider()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

            NewSessionRow(
                colorScheme: colorScheme,
                onTap: onNewSession
            )
        }
        .padding(5)
        .frame(width: 180)
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

private struct SessionOptionRow: View {
    let name: String
    let origin: SessionOrigin
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)
                SessionOriginBadge(origin: origin)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
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

private struct NewSessionRow: View {
    let colorScheme: ColorScheme
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .frame(width: 14)
                Text("New Session...")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
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
        isHovered ? Color.remarcPrimary(for: colorScheme).opacity(0.15) : .clear
    }
}
