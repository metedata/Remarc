import AppKit
import SwiftUI

/// The Annotate pill shown on the capture overlay before a session exists.
struct AnnotationEntryPill: View {
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Annotate")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(background)
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused
                        ? Color.remarcPrimary(for: colorScheme).opacity(0.9)
                        : Color.white.opacity(isEnabled ? 0.35 : 0.18),
                    lineWidth: isFocused ? 2 : 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable(isEnabled)
        .focused($isFocused)
        .help(isEnabled ? "Annotate this region (Shift Cmd A)" : "Preparing...")
        .accessibilityLabel("Annotate this region")
        .onHover { isHovered = $0 && isEnabled }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
        .animation(.easeInOut(duration: 0.12), value: isEnabled)
    }

    private var foreground: Color {
        // Even disabled it has to read as a control: the overlay behind it is 50%
        // black, so a 0.35-alpha white on a 0.35-alpha black pill vanished entirely.
        guard isEnabled else { return .white.opacity(0.5) }
        return isHovered || isPressed ? .white : .white.opacity(0.92)
    }

    private var background: Color {
        guard isEnabled else { return .black.opacity(0.75) }
        if isPressed { return Color.remarcPrimary(for: colorScheme).opacity(0.9) }
        if isHovered { return Color.remarcPrimary(for: colorScheme).opacity(0.7) }
        return .black.opacity(0.82)
    }
}

/// Hosts the pill in its own nonactivating panel, docked to the selection edge
/// opposite the comment panel.
@MainActor
final class AnnotationEntryPillController {

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnnotationEntryPill>?

    static let size = NSSize(width: 116, height: 28)

    var onActivate: (() -> Void)?

    /// Centred ABOVE the selection.
    ///
    /// Docking it opposite the comment panel put it off to one side, far from where
    /// the eye is. Above and centred reads as belonging to the region, and the size
    /// label sits below the selection so the two never collide.
    func show(selectionRectScreen rect: CGRect,
              panelEdge: StageDockEdge?,
              on screen: NSScreen,
              isEnabled: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let view = AnnotationEntryPill(isEnabled: isEnabled) { [weak self] in
            self?.onActivate?()
        }
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            self.hosting = hosting
        }

        // Clears the selection's corner handle arcs, which extend above the rect.
        let gap: CGFloat = 20
        var origin = CGPoint(x: (rect.midX - Self.size.width / 2).rounded(),
                             y: rect.maxY + gap)
        // Only when there is genuinely no room above does it go below, where the
        // size label lives, so it is offset past it.
        let visible = screen.visibleFrame
        if origin.y + Self.size.height > visible.maxY - 4 {
            origin.y = rect.minY - gap - Self.size.height - 24
        }
        _ = panelEdge
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - Self.size.width - 4))
        origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - Self.size.height - 4))

        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        return panel
    }

    func hide() { panel?.orderOut(nil) }

    func teardown() {
        hosting = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
