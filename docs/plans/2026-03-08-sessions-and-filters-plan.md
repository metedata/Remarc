# Sessions & Filters Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add session management (Inbox + custom sessions) and dynamic comment filters to the Remarc popover, plus session-aware export and move actions on comment cards.

**Architecture:** Two orthogonal features built on top of the existing `Session`/`Comment` data model. Sessions get a visual tab bar + picker dropdown. Filters get a dynamic pill bar. Both integrate into the existing popover layout. The `RemarcDropdown`/`DropdownPanelController` pattern is reused for all new dropdowns.

**Tech Stack:** SwiftUI, AppKit (NSPanel for dropdowns), existing `PersistenceManager`, `ExportManager`, `RemarcDropdown`/`DropdownPanelController` pattern.

**Design doc:** `docs/plans/2026-03-08-sessions-and-filters-design.md`

---

### Task 1: Inbox Session — Data Model & Migration

Make the first session permanent and named "Inbox". Protect it from rename/delete.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Session.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

**Step 1: Add `isInbox` to Session model**

In `Session.swift`, add a computed property:

```swift
var isInbox: Bool {
    // The Inbox is always the first session ever created (lowest createdAt)
    // PersistenceManager enforces this by naming it "Inbox" on creation
    name == AppConstants.inboxSessionName
}
```

**Step 2: Add constant for inbox name**

In `Constants.swift`, add to `AppConstants`:

```swift
public static let inboxSessionName: String = "Inbox"
```

**Step 3: Protect Inbox in PersistenceManager**

In `PersistenceManager.swift`:

- In `renameSession(_:to:)` (~line 105): guard against renaming Inbox
  ```swift
  func renameSession(_ id: UUID, to name: String) {
      guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
            !appState.sessions[index].isInbox else { return }
      // ... existing rename logic
  }
  ```

- In `deleteSession(_:)` (~line 111): guard against deleting Inbox
  ```swift
  func deleteSession(_ id: UUID) {
      guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
            !appState.sessions[index].isInbox else { return }
      // ... existing delete logic
  }
  ```

**Step 4: Migrate existing "Session 1" to "Inbox"**

In `PersistenceManager.swift`, in the initialization/load path, after loading `appState`:

```swift
// Migrate first session to Inbox if needed
if let firstIndex = appState.sessions.firstIndex(where: { !$0.isDeleted }) {
    if appState.sessions[firstIndex].name != AppConstants.inboxSessionName {
        appState.sessions[firstIndex].name = AppConstants.inboxSessionName
    }
}
```

Also update the auto-creation in `createComment()` (~line 244) to use "Inbox" instead of "Session 1":

```swift
if let session = createSession(name: AppConstants.inboxSessionName) {
```

**Step 5: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: Existing session renamed to "Inbox" in the app. Ask user to confirm.

**Step 7: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/Session.swift \
      app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift \
      app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift
git commit -m "feat(sessions): add Inbox as permanent default session with migration"
```

---

### Task 2: Session Bar View

Create the horizontal session pill bar for the popover header area.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`
- Reference: `app/RemarcPackage/Sources/RemarcFeature/Views/Colors.swift` (brand colors)

**Step 1: Create SessionBarView**

Create `SessionBarView.swift` with:

```swift
import SwiftUI

struct SessionBarView: View {
    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAddHovered = false
    @State private var renamingSessionID: UUID? = nil
    @State private var renameText: String = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(persistence.activeSessions) { session in
                    SessionPillView(
                        session: session,
                        isActive: session.id == persistence.appState.activeSessionID,
                        isRenaming: renamingSessionID == session.id,
                        renameText: $renameText,
                        onTap: { persistence.setActiveSession(session.id) },
                        onDoubleClick: { startRename(session) },
                        onRenameCommit: { commitRename(session) },
                        onRenameCancel: { cancelRename() }
                    )
                }

                addButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var addButton: some View {
        Button(action: createSession) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                if isAddHovered {
                    Text("New Session")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(.primary.opacity(isAddHovered ? 0.6 : 0.35))
            .padding(.horizontal, isAddHovered ? 8 : 6)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(.primary.opacity(isAddHovered ? 0.08 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(.primary.opacity(isAddHovered ? 0.12 : 0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isAddHovered = hovering
            }
        }
    }

    private func createSession() {
        let count = persistence.activeSessions.count
        let name = "Session \(count)"
        guard let session = persistence.createSession(name: name) else { return }
        persistence.setActiveSession(session.id)
        // Start inline rename immediately
        renamingSessionID = session.id
        renameText = name
    }

    private func startRename(_ session: Session) {
        guard !session.isInbox else { return }
        renamingSessionID = session.id
        renameText = session.name
    }

    private func commitRename(_ session: Session) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != session.name {
            persistence.renameSession(session.id, to: trimmed)
        }
        renamingSessionID = nil
    }

    private func cancelRename() {
        renamingSessionID = nil
    }
}
```

**Step 2: Create SessionPillView**

Add to the same file or a separate file — a pill that shows session name, handles tap/double-click/rename:

```swift
struct SessionPillView: View {
    let session: Session
    let isActive: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onTap: () -> Void
    let onDoubleClick: () -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Group {
            if isRenaming {
                renameField
            } else {
                pillButton
            }
        }
    }

    private var pillButton: some View {
        Text(session.name)
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(backgroundColor))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
            .contentShape(Capsule())
            .onTapGesture(count: 2) { onDoubleClick() }
            .onTapGesture(count: 1) { onTap() }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .contextMenu { contextMenuItems }
    }

    private var renameField: some View {
        TextField("Session name", text: $renameText, onCommit: onRenameCommit)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.remarcPrimary(for: colorScheme).opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.3), lineWidth: 0.5))
            .onExitCommand { onRenameCancel() }
            // Click outside commits — handle via focus loss
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if !session.isInbox {
            Button("Rename") { onDoubleClick() }
            Button("Delete", role: .destructive) {
                PersistenceManager.shared.deleteSession(session.id)
            }
        }
    }

    private var foregroundColor: Color {
        isActive ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(isHovered ? 0.7 : 0.5)
    }

    private var backgroundColor: Color {
        isActive ? Color.remarcPrimary(for: colorScheme).opacity(0.12)
            : isHovered ? .primary.opacity(0.06) : .clear
    }

    private var borderColor: Color {
        isActive ? Color.remarcPrimary(for: colorScheme).opacity(0.25)
            : isHovered ? .primary.opacity(0.1) : .primary.opacity(0.06)
    }
}
```

**Step 3: Integrate SessionBarView into PopoverContentView**

In `PopoverContentView.swift`, add `SessionBarView()` between the header and the comment list. Look for the `normalHeader` section (~line 172) — the session bar goes right after the header `VStack` and before the comment `ScrollView`:

```swift
// After header section, before comment list
SessionBarView()
Divider().padding(.horizontal, 12)
```

**Step 4: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: Session bar visible with "Inbox" pill and "+" button. Ask user to confirm visually.

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift \
      app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift
git commit -m "feat(sessions): add session bar with pills and new session button"
```

---

### Task 3: Session Pill in Comment Footer

Add the session picker dropdown to CommentInputView and CommentEditorView footers.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/SessionPickerPill.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentEditorView.swift`
- Reference: `app/RemarcPackage/Sources/RemarcFeature/Views/RemarcDropdown.swift` (DropdownPanelController pattern)
- Reference: `app/RemarcPackage/Sources/RemarcFeature/Views/StatusDotView.swift` (anchor + dropdown usage)

**Step 1: Create SessionPickerPill**

A compact capsule-style button that opens a dropdown panel listing sessions + "New Session...". Reuses `DropdownPanelController` and `AnchorViewRef`/`DropdownAnchor` from `RemarcDropdown.swift`.

```swift
import SwiftUI

struct SessionPickerPill: View {
    @Binding var selectedSessionID: UUID
    let onNewSession: ((String) -> UUID?)? // Returns new session ID if created
    let onSessionChanged: ((UUID) -> Void)? // Called when user picks a different session

    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var anchorRef = AnchorViewRef()
    @State private var isCreatingNew = false
    @State private var newSessionName = ""

    private var selectedSession: Session? {
        persistence.activeSessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        Group {
            if isCreatingNew {
                newSessionField
            } else {
                pillButton
            }
        }
    }

    private var pillButton: some View {
        Button {
            if isOpen {
                DropdownPanelController.shared.dismiss()
            } else {
                showDropdown()
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedSession?.name ?? "Inbox")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(chevronColor)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(backgroundColor))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
            .overlay(DropdownAnchor(ref: anchorRef))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var newSessionField: some View {
        TextField("Session name", text: $newSessionName, onCommit: commitNewSession)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.remarcPrimary(for: colorScheme).opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.3), lineWidth: 0.5))
            .frame(width: 120)
            .onExitCommand { cancelNewSession() }
    }

    private func showDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        isOpen = true
        let cs = colorScheme

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            onDismiss: { isOpen = false }
        ) {
            SessionDropdownPanel(
                sessions: persistence.activeSessions,
                currentSessionID: selectedSessionID,
                colorScheme: cs,
                onSelect: { sessionID in
                    if sessionID != selectedSessionID {
                        selectedSessionID = sessionID
                        onSessionChanged?(sessionID)
                    }
                    DropdownPanelController.shared.dismiss()
                },
                onNewSession: {
                    DropdownPanelController.shared.dismiss()
                    isCreatingNew = true
                    newSessionName = ""
                }
            )
        }
    }

    private func commitNewSession() {
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelNewSession()
            return
        }
        if let newID = onNewSession?(trimmed) {
            selectedSessionID = newID
            onSessionChanged?(newID)
        }
        isCreatingNew = false
    }

    private func cancelNewSession() {
        isCreatingNew = false
    }

    // Colors follow RemarcDropdown pattern
    private var textColor: Color {
        isOpen ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.6)
    }
    private var chevronColor: Color {
        isOpen ? Color.remarcPrimary(for: colorScheme)
            : isHovered ? .primary.opacity(0.5) : .primary.opacity(0.35)
    }
    private var backgroundColor: Color {
        isOpen ? Color.remarcPrimary(for: colorScheme).opacity(0.12)
            : isHovered ? .primary.opacity(0.06) : .clear
    }
    private var borderColor: Color {
        isOpen ? Color.remarcPrimary(for: colorScheme).opacity(0.3)
            : isHovered ? .primary.opacity(0.12) : .primary.opacity(0.06)
    }
}
```

**Step 2: Create SessionDropdownPanel**

In the same file, add the dropdown content:

```swift
struct SessionDropdownPanel: View {
    let sessions: [Session]
    let currentSessionID: UUID
    let colorScheme: ColorScheme
    let onSelect: (UUID) -> Void
    let onNewSession: () -> Void

    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionOptionRow(
                    name: session.name,
                    isSelected: session.id == currentSessionID,
                    colorScheme: colorScheme,
                    onSelect: { onSelect(session.id) }
                )
            }

            Divider().padding(.horizontal, 6).padding(.vertical, 2)

            NewSessionRow(colorScheme: colorScheme, onTap: onNewSession)
        }
        .padding(5)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(panelBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}
```

Add `SessionOptionRow` and `NewSessionRow` following the same pattern as `StatusOptionRow` in `StatusDotView.swift` — checkmark on left for selected, hover highlight, etc. `NewSessionRow` shows a `plus` icon instead of checkmark.

**Step 3: Add SessionPickerPill to CommentInputView footer**

In `CommentInputView.swift`, in the footer `HStack` (~line 51), add the pill before the paperclip:

```swift
HStack(alignment: .center) {
    SessionPickerPill(
        selectedSessionID: $targetSessionID,
        onNewSession: { name in
            persistence.createSession(name: name)?.id
        },
        onSessionChanged: nil // Just changes which session the comment will be saved to
    )

    Button(action: pickAttachmentImage) {
        // ... existing paperclip button
    }
    // ... rest of footer
}
```

Add state: `@State private var targetSessionID: UUID = PersistenceManager.shared.appState.activeSessionID ?? UUID()`

Pass `targetSessionID` to `controller.saveComment()` so the comment is created in the selected session.

**Step 4: Add SessionPickerPill to CommentEditorView footer**

In `CommentEditorView.swift`, in the footer `HStack` (~line 96), add the pill. For the editor, selecting a different session moves the comment immediately:

```swift
SessionPickerPill(
    selectedSessionID: $commentSessionID,
    onNewSession: { name in
        PersistenceManager.shared.createSession(name: name)?.id
    },
    onSessionChanged: { newSessionID in
        guard let comment else { return }
        PersistenceManager.shared.moveComment(comment.id, to: newSessionID)
        ToastManager.shared.show("Moved to \(newSessionName)", undo: {
            PersistenceManager.shared.moveComment(comment.id, to: oldSessionID)
        })
    }
)
```

Initialize `commentSessionID` from `comment.sessionID`.

**Step 5: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: Session pill visible in both comment input and editor footers. Dropdown works, "New Session..." creates inline. Ask user to confirm.

**Step 7: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/SessionPickerPill.swift \
      app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift \
      app/RemarcPackage/Sources/RemarcFeature/Views/CommentEditorView.swift
git commit -m "feat(sessions): add session picker pill to comment input and editor footers"
```

---

### Task 4: Move Button on Comment Cards

Add `arrow.forward.folder` action to card hover actions with session picker dropdown.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

**Step 1: Add move button to card actions**

In `CommentCardView.swift`, in `cardActions` (~line 204), add between edit and delete:

```swift
private var cardActions: some View {
    HStack(spacing: 4) {
        cardActionButton(icon: "doc.on.doc", tooltip: "Copy", tint: Color.remarcPrimary(for: colorScheme)) {
            ExportManager.shared.copyCommentToClipboard(comment)
            ToastManager.shared.show("Copied to clipboard")
        }
        cardActionButton(icon: "pencil", tooltip: "Edit", tint: Color.remarcPrimary(for: colorScheme)) {
            FloatingEditorController.shared.showForEdit(comment: comment)
        }

        // Move button with session picker
        MoveToSessionButton(comment: comment)

        cardActionButton(icon: "trash", tooltip: "Delete", tint: Color.remarcError(for: colorScheme)) {
            showDeleteConfirmation = true
        }
        .popover(isPresented: $showDeleteConfirmation, arrowEdge: .bottom) {
            deleteConfirmationPopover
        }
    }
}
```

**Step 2: Create MoveToSessionButton**

Add to `CommentCardView.swift` or a separate file. Uses `DropdownPanelController` to show session list:

```swift
struct MoveToSessionButton: View {
    let comment: Comment
    @ObservedObject private var persistence = PersistenceManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var anchorRef = AnchorViewRef()

    var body: some View {
        Button(action: showMoveDropdown) {
            Image(systemName: "arrow.forward.folder")
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .overlay(DropdownAnchor(ref: anchorRef))
        }
        .buttonStyle(.plain)
        .help("Move to session")
        .onHover { hovering in isHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func showMoveDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        let cs = colorScheme
        let otherSessions = persistence.activeSessions.filter { $0.id != comment.sessionID }
        guard !otherSessions.isEmpty || persistence.activeSessions.count < AppConstants.maxActiveSessions else { return }

        isOpen = true
        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            onDismiss: { isOpen = false }
        ) {
            SessionDropdownPanel(
                sessions: persistence.activeSessions.filter { $0.id != comment.sessionID },
                currentSessionID: comment.sessionID, // None will be "selected" since we filter it out
                colorScheme: cs,
                onSelect: { targetSessionID in
                    let oldSessionID = comment.sessionID
                    let targetName = persistence.activeSessions.first { $0.id == targetSessionID }?.name ?? "session"
                    persistence.moveComment(comment.id, to: targetSessionID)
                    DropdownPanelController.shared.dismiss()
                    ToastManager.shared.show("Moved to \(targetName)", undo: {
                        persistence.moveComment(comment.id, to: oldSessionID)
                    })
                },
                onNewSession: {
                    DropdownPanelController.shared.dismiss()
                    // Create new session and move
                    let count = persistence.activeSessions.count
                    if let newSession = persistence.createSession(name: "Session \(count)") {
                        let oldSessionID = comment.sessionID
                        persistence.moveComment(comment.id, to: newSession.id)
                        ToastManager.shared.show("Moved to \(newSession.name)", undo: {
                            persistence.moveComment(comment.id, to: oldSessionID)
                        })
                    }
                }
            )
        }
    }
}
```

**Step 3: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: Move icon appears on card hover. Dropdown shows other sessions. Moving shows toast with undo. Ask user to confirm.

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift
git commit -m "feat(sessions): add move-to-session button on comment cards"
```

---

### Task 5: Filter Bar View

Create the dynamic filter pill bar that sits below the session bar.

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/FilterBarView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Create FilterState model**

Add to `FilterBarView.swift` or a separate models file:

```swift
import SwiftUI

@MainActor
final class FilterState: ObservableObject {
    @Published var selectedApps: Set<String> = []
    @Published var selectedTypes: Set<CommentType.Kind> = [] // Need a hashable kind enum
    @Published var selectedStatuses: Set<CommentStatus> = []
    @Published var hasAttachmentFilter: Bool? = nil // nil = no filter, true = with, false = without

    var isActive: Bool {
        !selectedApps.isEmpty || !selectedTypes.isEmpty || !selectedStatuses.isEmpty || hasAttachmentFilter != nil
    }

    func reset() {
        selectedApps = []
        selectedTypes = []
        selectedStatuses = []
        hasAttachmentFilter = nil
    }

    func apply(to comments: [Comment]) -> [Comment] {
        var result = comments

        if !selectedApps.isEmpty {
            result = result.filter { selectedApps.contains($0.source) }
        }
        if !selectedTypes.isEmpty {
            result = result.filter { selectedTypes.contains($0.type.kind) }
        }
        if !selectedStatuses.isEmpty {
            result = result.filter { selectedStatuses.contains($0.status) }
        }
        if let hasAttachment = hasAttachmentFilter {
            result = result.filter { hasAttachment ? !$0.attachments.isEmpty : $0.attachments.isEmpty }
        }

        return result
    }
}
```

Note: `CommentType` is an enum with associated values, so we need a `Kind` enum for hashing. Add to `Comment.swift`:

```swift
extension CommentType {
    enum Kind: String, Hashable, CaseIterable {
        case comment, screenshot, quickNote, critMode
    }

    var kind: Kind {
        switch self {
        case .comment: return .comment
        case .screenshot: return .screenshot
        case .quickNote: return .quickNote
        case .critMode: return .critMode
        }
    }
}
```

**Step 2: Create FilterBarView**

```swift
struct FilterBarView: View {
    @ObservedObject var filterState: FilterState
    let comments: [Comment] // Unfiltered comments in current session
    @Environment(\.colorScheme) private var colorScheme

    // Computed: which dimensions have variety
    private var distinctApps: [String] {
        Array(Set(comments.map(\.source))).sorted()
    }
    private var distinctTypes: [CommentType.Kind] {
        Array(Set(comments.map(\.type.kind))).sorted(by: { $0.rawValue < $1.rawValue })
    }
    private var distinctStatuses: [CommentStatus] {
        Array(Set(comments.map(\.status)))
    }
    private var hasAttachmentVariety: Bool {
        let withAttach = comments.contains { !$0.attachments.isEmpty }
        let withoutAttach = comments.contains { $0.attachments.isEmpty }
        return withAttach && withoutAttach
    }

    private var showBar: Bool {
        distinctApps.count > 1 || distinctTypes.count > 1 || distinctStatuses.count > 1 || hasAttachmentVariety
    }

    var body: some View {
        if showBar {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Source app pills
                    if distinctApps.count > 1 {
                        ForEach(distinctApps, id: \.self) { app in
                            FilterPill(
                                label: app,
                                isSelected: filterState.selectedApps.contains(app),
                                colorScheme: colorScheme
                            ) {
                                toggleApp(app)
                            }
                        }
                    }

                    // Separator between dimensions
                    if distinctApps.count > 1 && distinctTypes.count > 1 {
                        separatorDot
                    }

                    // Type pills
                    if distinctTypes.count > 1 {
                        ForEach(distinctTypes, id: \.self) { type in
                            FilterPill(
                                label: type.displayName,
                                isSelected: filterState.selectedTypes.contains(type),
                                colorScheme: colorScheme
                            ) {
                                toggleType(type)
                            }
                        }
                    }

                    // Status pills
                    if distinctStatuses.count > 1 {
                        if distinctTypes.count > 1 || distinctApps.count > 1 { separatorDot }
                        ForEach(distinctStatuses, id: \.self) { status in
                            FilterPill(
                                label: status.label,
                                isSelected: filterState.selectedStatuses.contains(status),
                                colorScheme: colorScheme
                            ) {
                                toggleStatus(status)
                            }
                        }
                    }

                    // Attachment toggle
                    if hasAttachmentVariety {
                        if distinctStatuses.count > 1 || distinctTypes.count > 1 || distinctApps.count > 1 { separatorDot }
                        FilterPill(
                            label: "Has attachment",
                            isSelected: filterState.hasAttachmentFilter == true,
                            colorScheme: colorScheme
                        ) {
                            filterState.hasAttachmentFilter = filterState.hasAttachmentFilter == true ? nil : true
                        }
                    }

                    // Clear all
                    if filterState.isActive {
                        Button(action: { filterState.reset() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .help("Clear filters")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    private var separatorDot: some View {
        Circle()
            .fill(.primary.opacity(0.15))
            .frame(width: 3, height: 3)
    }

    private func toggleApp(_ app: String) {
        if filterState.selectedApps.contains(app) {
            filterState.selectedApps.remove(app)
        } else {
            filterState.selectedApps.insert(app)
        }
    }

    private func toggleType(_ type: CommentType.Kind) {
        if filterState.selectedTypes.contains(type) {
            filterState.selectedTypes.remove(type)
        } else {
            filterState.selectedTypes.insert(type)
        }
    }

    private func toggleStatus(_ status: CommentStatus) {
        if filterState.selectedStatuses.contains(status) {
            filterState.selectedStatuses.remove(status)
        } else {
            filterState.selectedStatuses.insert(status)
        }
    }
}

struct FilterPill: View {
    let label: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 10, weight: isSelected ? .medium : .regular))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(backgroundColor))
                .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }

    private var foregroundColor: Color {
        isSelected ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(isHovered ? 0.6 : 0.45)
    }
    private var backgroundColor: Color {
        isSelected ? Color.remarcPrimary(for: colorScheme).opacity(0.12) : isHovered ? .primary.opacity(0.05) : .clear
    }
    private var borderColor: Color {
        isSelected ? Color.remarcPrimary(for: colorScheme).opacity(0.25) : .primary.opacity(isHovered ? 0.1 : 0.06)
    }
}
```

**Step 3: Add `Kind.displayName`**

In `Comment.swift`, on the `CommentType.Kind` extension:

```swift
var displayName: String {
    switch self {
    case .comment: return "Comment"
    case .screenshot: return "Screenshot"
    case .quickNote: return "Quick Note"
    case .critMode: return "Crit"
    }
}
```

**Step 4: Integrate FilterBarView into PopoverContentView**

In `PopoverContentView.swift`:
- Add `@StateObject private var filterState = FilterState()`
- Insert `FilterBarView(filterState: filterState, comments: persistence.activeComments)` after the session bar
- Modify the `comments` computed property to apply filter:
  ```swift
  private var comments: [Comment] {
      let base = filterState.apply(to: persistence.activeComments)
      let searched = searchText.isEmpty ? base : base.filter { /* existing search logic */ }
      return sortNewestFirst ? searched.reversed() : searched
  }
  ```
- Update header count to show filtered vs total: `"\(comments.count) of \(persistence.activeComments.count) remarks"` when `filterState.isActive`
- Reset filters when active session changes:
  ```swift
  .onChange(of: persistence.appState.activeSessionID) {
      filterState.reset()
  }
  ```

**Step 5: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: Filter bar appears only when variety exists. Pills toggle correctly. Count updates. Switching sessions resets filters. Ask user to confirm.

**Step 7: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/FilterBarView.swift \
      app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift \
      app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift
git commit -m "feat(filters): add dynamic filter bar with source app, type, status, and attachment filters"
```

---

### Task 6: Export Chevron & MCP Hint

Add chevron dropdown to "Copy All" when filters active or multiple sessions, and update MCP hint to include session name.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Update MCP hint in ExportManager**

In `ExportManager.swift`, in `previewLines()` method (~line 510–512), update the hint to include session name. The method needs to accept a session name parameter:

Find the AI hint line and update:

```swift
// Old:
"<!-- To update these comments, use the Remarc MCP tools (remarc_resolve, remarc_reopen). -->"

// New (session-aware):
"<!-- These remarks are from the '\(sessionName)' session in Remarc. Use MCP tool remarc_list_comments with session_id to read and resolve them. -->"
```

Thread the `sessionName` parameter through `markdownForSession()` → `previewLines()` → hint text.

**Step 2: Update MCP prompt button in PopoverContentView**

In `PopoverContentView.swift` (~line 580), update the copied prompt to include session info:

```swift
let sessionName = persistence.activeSession?.name ?? "Inbox"
let prompt = "I left review comments in the '\(sessionName)' session using Remarc. Use remarc_list_sessions to find the session ID, then remarc_list_comments with that session_id to see them, and resolve each one."
```

**Step 3: Add chevron to Copy All button**

In `PopoverContentView.swift`, in the footer section where "Copy All" lives, check if filters are active or multiple sessions exist. If so, show a chevron that opens a dropdown with options:

```swift
private var needsCopyOptions: Bool {
    filterState.isActive || persistence.activeSessions.count > 1
}

// Replace simple "Copy All" button with:
if needsCopyOptions {
    // Split button: left side copies session, right chevron shows options
    HStack(spacing: 0) {
        Button(action: copyAll) {
            Text("Copy All")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)

        Button(action: showCopyOptions) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }
} else {
    // Simple Copy All as before
    Button(action: copyAll) { /* ... existing ... */ }
}
```

The dropdown offers:
- "Copy filtered (\(comments.count))" — when filters active, copies only visible comments
- "Copy session (\(persistence.activeComments.count))" — copies all comments in active session regardless of filters

**Step 4: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Relaunch and verify**

Run: `bash scripts/relaunch.sh`
Verify: MCP hint includes session name. Copy All chevron appears when filters active or multiple sessions. Dropdown shows correct options. Ask user to confirm.

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift \
      app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift
git commit -m "feat(export): add copy options chevron and session name in MCP hint"
```

---

### Task 7: Bump Session Limit & Polish

Final cleanup: bump session limit, handle edge cases.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift` (if overflow needs handling)

**Step 1: Bump maxActiveSessions**

In `Constants.swift` (~line 67):

```swift
// Old: public static let maxActiveSessions: Int = 3
public static let maxActiveSessions: Int = 8
```

Choose a reasonable limit that the session bar can handle with horizontal scrolling. 8 is generous without being unlimited.

**Step 2: Disable "+" button when at limit**

In `SessionBarView.swift`, disable or hide the add button when at max:

```swift
if persistence.activeSessions.count < AppConstants.maxActiveSessions {
    addButton
}
```

**Step 3: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Relaunch and final verification**

Run: `bash scripts/relaunch.sh`
Full verification checklist:
- [ ] Inbox session present, can't rename or delete
- [ ] "+" creates new session with inline rename
- [ ] Double-click renames, click outside commits
- [ ] Session pills switch context, filters reset
- [ ] Session picker pill in comment input footer
- [ ] Session picker pill in editor footer (moves immediately with toast)
- [ ] Move button on card hover, dropdown works
- [ ] Filter bar appears only with variety, toggles work
- [ ] Header count shows filtered/total when filtering
- [ ] Copy All chevron with options when filters/multi-session
- [ ] MCP hint includes session name

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift \
      app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift
git commit -m "feat(sessions): bump session limit to 8 and disable add at max"
```
