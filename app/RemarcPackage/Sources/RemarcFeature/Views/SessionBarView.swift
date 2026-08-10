import SwiftUI

// MARK: - Session Bar View

/// Horizontal pill bar for switching between active sessions.
/// Shows capsule-shaped pills for each session, with a "+" button to create new ones.
struct SessionBarView: View {
    @ObservedObject private var persistence = PersistenceManager.shared
    @ObservedObject private var popoverController = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var renamingSessionID: UUID?
    @State private var renameText: String = ""
    @State private var pendingNewSessionID: UUID?
    @State private var deletingSessionIDs: Set<UUID> = []

    /// Pre-compute comment counts per session once per render instead of O(s*n) per pill.
    private var commentCountsBySession: [UUID: Int] {
        Dictionary(
            persistence.allComments.map { ($0.sessionID, 1) },
            uniquingKeysWith: +
        )
    }

    var body: some View {
        let counts = commentCountsBySession
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(persistence.activeSessions) { session in
                        if renamingSessionID == session.id {
                            inlineRenameField(for: session)
                                .id(session.id)
                        } else {
                            sessionPill(for: session, counts: counts)
                                .id(session.id)
                        }
                    }

                    newSessionButton
                }
                .padding(.leading, 14)
                .padding(.trailing, 80)
                .padding(.vertical, 8)
                .background {
                    // Tap empty space in the bar to dismiss active rename
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            commitActiveRename()
                        }
                }
            }
            .onAppear {
                if let activeID = persistence.appState.activeSessionID {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
            .onChange(of: popoverController.isVisible) { _, visible in
                if visible, let activeID = persistence.appState.activeSessionID {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
            .onChange(of: persistence.appState.activeSessionID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Session Pill

    private func sessionPill(for session: Session, counts: [UUID: Int] = [:]) -> some View {
        let isActive = persistence.appState.activeSessionID == session.id
        let count = counts[session.id] ?? 0

        return SessionPillView(
            session: session,
            isActive: isActive,
            commentCount: count,
            colorScheme: colorScheme,
            isBeingDeleted: deletingSessionIDs.contains(session.id),
            onTap: {
                commitActiveRename()
                persistence.setActiveSession(session.id)
            },
            onDoubleClick: {
                guard !session.isInbox else { return }
                beginRename(session)
            },
            contextMenu: {
                sessionContextMenu(for: session)
            }
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        if !session.isInbox {
            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                animateDeleteSession(session.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Animated Delete

    private func animateDeleteSession(_ sessionID: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            deletingSessionIDs.insert(sessionID)
        } completion: {
            deletingSessionIDs.remove(sessionID)
            persistence.deleteSession(sessionID)
        }
    }

    // MARK: - Inline Rename

    private func inlineRenameField(for session: Session) -> some View {
        SessionRenameField(
            text: $renameText,
            brandColor: Color.remarcPrimary(for: colorScheme),
            colorScheme: colorScheme,
            onCommit: {
                commitRename(session)
            },
            onCancel: {
                cancelRename()
            }
        )
    }

    private func beginRename(_ session: Session) {
        renameText = session.name
        renamingSessionID = session.id
    }

    private func commitRename(_ session: Session) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            persistence.renameSession(session.id, to: trimmed)
        }
        renamingSessionID = nil
        pendingNewSessionID = nil
    }

    private func cancelRename() {
        // If this was a pending new session with no name committed, delete it
        if let newID = pendingNewSessionID, newID == renamingSessionID {
            persistence.deleteSession(newID)
            pendingNewSessionID = nil
        }
        renamingSessionID = nil
    }

    /// Commit any active rename (called when clicking elsewhere in the bar).
    private func commitActiveRename() {
        guard let sessionID = renamingSessionID,
              let session = persistence.activeSessions.first(where: { $0.id == sessionID }) else { return }
        commitRename(session)
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        NewSessionPillButton(
            colorScheme: colorScheme,
            canCreate: persistence.activeSessions.count < AppConstants.maxActiveSessions,
            suppressHover: renamingSessionID != nil,
            onCreate: {
                createNewSession()
            }
        )
    }

    private func createNewSession() {
        let name = SessionNaming.nextName()
        guard let session = persistence.createSession(name: name) else { return }
        persistence.setActiveSession(session.id)
        pendingNewSessionID = session.id
        beginRename(session)
    }
}

// MARK: - Session Pill View

/// Individual session pill with hover, tap, double-click, and context menu support.
/// Uses manual double-click detection to avoid SwiftUI's tap disambiguation delay.
private struct SessionPillView<MenuContent: View>: View {
    let session: Session
    let isActive: Bool
    let commentCount: Int
    let colorScheme: ColorScheme
    var isBeingDeleted: Bool = false
    let onTap: () -> Void
    let onDoubleClick: () -> Void
    @ViewBuilder let contextMenu: () -> MenuContent

    @State private var isHovered = false
    @State private var lastClickDate: Date?

    private var isMuted: Bool {
        !isActive && commentCount == 0
    }

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button(action: handleClick) {
            HStack(spacing: 4) {
                SessionOriginBadge(origin: session.origin)

                Text(session.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(
                        isActive
                            ? brandColor
                            : .primary.opacity(isMuted ? 0.35 : 0.6)
                    )
                    .lineLimit(1)

                Text("\(commentCount)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isActive
                            ? brandColor.opacity(0.7)
                            : .primary.opacity(isMuted ? 0.25 : 0.4)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pillBackground(isActive: isActive, brandColor: brandColor))
            .overlay(pillBorder(isActive: isActive, brandColor: brandColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        // Delete animation — below implicit animations so they don't block it
        .opacity(isBeingDeleted ? 0 : 1)
        .scaleEffect(isBeingDeleted ? 0.01 : 1.0)
        .frame(width: isBeingDeleted ? 0 : nil)
        .clipped()
    }

    private func handleClick() {
        let now = Date()
        if let last = lastClickDate, now.timeIntervalSince(last) < 0.3 {
            lastClickDate = nil
            onDoubleClick()
        } else {
            lastClickDate = now
            onTap()
        }
    }

    private func pillBackground(isActive: Bool, brandColor: Color) -> some View {
        Capsule()
            .fill(
                isActive
                    ? brandColor.opacity(0.12)
                    : Color.primary.opacity(isHovered ? 0.06 : 0)
            )
    }

    private func pillBorder(isActive: Bool, brandColor: Color) -> some View {
        Capsule()
            .strokeBorder(
                isActive ? brandColor.opacity(0.25) : Color.clear,
                lineWidth: 1
            )
    }
}

// MARK: - Inline Rename Field

/// A text field that replaces a pill during inline rename.
/// Commits on Enter or focus loss, cancels on Esc or empty text.
private struct SessionRenameField: View {
    @Binding var text: String
    let brandColor: Color
    let colorScheme: ColorScheme
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var clickMonitor: Any?

    var body: some View {
        TextField("Session name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(brandColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(brandColor.opacity(0.4), lineWidth: 1)
            )
            .frame(minWidth: 60, maxWidth: 140)
            .focused($isFocused)
            .onAppear {
                // Ensure the panel is key so the field editor draws the caret.
                // Non-activating panels don't auto-become-key from button clicks.
                MenuBarPopoverController.shared.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
                // Install click-outside monitor: any click not on a text field
                // resigns first responder, triggering focus-loss commit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                        if let window = event.window,
                           let hitView = window.contentView?.hitTest(event.locationInWindow) {
                            var view: NSView? = hitView
                            while let v = view {
                                if v is NSTextField { return event }
                                view = v.superview
                            }
                        }
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return event
                    }
                }
            }
            .onDisappear {
                if let monitor = clickMonitor {
                    NSEvent.removeMonitor(monitor)
                    clickMonitor = nil
                }
            }
            .onSubmit {
                handleCommit()
            }
            .onKeyPress(.escape) {
                onCancel()
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    handleCommit()
                }
            }
    }

    private func handleCommit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCancel()
        } else {
            onCommit()
        }
    }
}

// MARK: - New Session Pill Button

/// "+" button that expands on hover to reveal "New Session" label.
/// At the session limit, stays compact with muted styling and shows a toast on click.
private struct NewSessionPillButton: View {
    let colorScheme: ColorScheme
    let canCreate: Bool
    var suppressHover: Bool = false
    let onCreate: () -> Void

    @State private var isHovered = false

    private var effectiveHover: Bool { isHovered && !suppressHover }

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button {
            if canCreate {
                onCreate()
            } else {
                ToastManager.shared.show("Session limit reached")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))

                if canCreate {
                    Text("New Session")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(effectiveHover ? 1 : 0)
                        .frame(width: effectiveHover ? nil : 0, alignment: .leading)
                        .clipped()
                }
            }
            .foregroundStyle(canCreate
                ? (effectiveHover ? brandColor : .primary.opacity(0.45))
                : .primary.opacity(0.2))
            .padding(.horizontal, canCreate && effectiveHover ? 10 : 6)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(effectiveHover && canCreate ? brandColor.opacity(0.12) : .clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(brandColor.opacity(effectiveHover && canCreate ? 0.25 : 0), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: suppressHover)
        .help("New session")
    }
}

// MARK: - Session Naming

/// Generates sequential session names: "Session A", "Session B", ..., "Session Z", "Session AA", ...
@MainActor
enum SessionNaming {
    static func nextName() -> String {
        let existingNames = Set(PersistenceManager.shared.activeSessions.map(\.name))
        for i in 0... {
            let name = "Session \(letterLabel(for: i))"
            if !existingNames.contains(name) { return name }
        }
        return "Session" // Fallback (unreachable)
    }

    private static func letterLabel(for index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            result = String(Character(UnicodeScalar(65 + (n % 26))!)) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }
}
