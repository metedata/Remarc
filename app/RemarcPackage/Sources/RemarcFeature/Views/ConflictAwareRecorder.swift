import KeyboardShortcuts
import SwiftUI

/// Display name mapping for all app shortcut names.
/// Used in conflict detection toasts and fn toggle toasts.
extension KeyboardShortcuts.Name {
    // KeyboardShortcuts.Name is a struct, not an enum — use if/else, not switch.
    var displayName: String {
        if self == .commentOnSelection { return "Comment on Selection" }
        if self == .screenshotComment { return "Screenshot" }
        if self == .screenshotCommentWake { return "Screenshot & Send Instantly" }
        if self == .pasteAllComments { return "Paste All" }
        if self == .voiceInput { return "Voice Input" }
        if self == .dictation { return "Push to Talk" }
        if self == .dictationHandsFree { return "Hands-free Shortcut" }
        if self == .pasteLastTranscription { return "Paste Last Transcription" }
        if self == .openRemarc { return "Open Remarc" }
        if self == .startCritMode { return "Start Crit Mode" }
        return rawValue
    }

    /// All shortcut names that participate in conflict detection.
    static let allAppShortcuts: [KeyboardShortcuts.Name] = [
        .commentOnSelection,
        .screenshotComment,
        .screenshotCommentWake,
        .pasteAllComments,
        .voiceInput,
        .dictation,
        .dictationHandsFree,
        .pasteLastTranscription,
        .openRemarc,
        .startCritMode,
    ]
}

/// A wrapper around `KeyboardShortcuts.Recorder` that detects intra-app
/// shortcut conflicts. If a newly-recorded shortcut duplicates another slot,
/// the recorder reverts to the previous shortcut and shows a toast.
struct ConflictAwareRecorder: View {
    let name: KeyboardShortcuts.Name
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        KeyboardShortcuts.Recorder("", name: name) { newShortcut in
            guard let newShortcut else {
                // User cleared the shortcut — no conflict possible
                previousShortcut = nil
                return
            }

            // Check all other names for conflicts
            for otherName in KeyboardShortcuts.Name.allAppShortcuts where otherName != name {
                if KeyboardShortcuts.getShortcut(for: otherName) == newShortcut {
                    // Conflict found — revert to previous
                    KeyboardShortcuts.setShortcut(previousShortcut, for: name)
                    ToastManager.shared.show("Shortcut already used by \(otherName.displayName)")
                    return
                }
            }

            // No conflict — accept the new shortcut
            previousShortcut = newShortcut
        }
        .onAppear {
            previousShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
    }
}
