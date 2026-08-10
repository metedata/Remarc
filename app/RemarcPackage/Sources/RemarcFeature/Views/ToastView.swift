import SwiftUI

@MainActor
@Observable
final class ToastManager {
    static let shared = ToastManager()

    var currentToast: ToastItem?

    struct ToastItem: Identifiable {
        let id = UUID()
        let message: String
        var undoAction: (() -> Void)?
        var duration: TimeInterval = 2.0
    }

    func show(_ message: String, undo: (() -> Void)? = nil, duration: TimeInterval = 2.0) {
        let toast = ToastItem(message: message, undoAction: undo, duration: duration)
        currentToast = toast
        let toastID = toast.id
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if currentToast?.id == toastID {
                currentToast = nil
            }
        }
    }

    func dismiss() {
        currentToast = nil
    }
}

struct ToastOverlay: View {
    let toast: ToastManager.ToastItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            if let undo = toast.undoAction {
                Button("Undo") {
                    undo()
                    ToastManager.shared.dismiss()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.08),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
