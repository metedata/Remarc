import SwiftUI
import AppKit

// MARK: - Panel Controller

@MainActor
final class DropdownPanelController {
    static let shared = DropdownPanelController()
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var onDismiss: (() -> Void)?
    private var triggerScreenFrame: NSRect = .zero

    private init() {}

    func show<Content: View>(
        below anchorScreenFrame: NSRect,
        width: CGFloat,
        colorScheme: ColorScheme,
        anchorWindowLevel: NSWindow.Level? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        dismiss()
        self.triggerScreenFrame = anchorScreenFrame

        let hostingView = NSHostingView(rootView:
            content().environment(\.colorScheme, colorScheme)
        )
        let fittingSize = hostingView.fittingSize

        let panelFrame = NSRect(
            x: anchorScreenFrame.origin.x,
            y: anchorScreenFrame.origin.y - fittingSize.height - 2,
            width: width,
            height: fittingSize.height
        )

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let baseLevel = anchorWindowLevel ?? .popUpMenu
        panel.level = NSWindow.Level(rawValue: baseLevel.rawValue + 10)
        panel.contentView = hostingView
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.onDismiss = onDismiss

        // Local monitor for clicks within the app.
        // Note: addLocalMonitorForEvents doesn't fire reliably for .nonactivatingPanel
        // windows, so we also install a global monitor as fallback.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let mouse = NSEvent.mouseLocation
            if !panel.frame.contains(mouse) && !self.triggerScreenFrame.contains(mouse) {
                self.dismiss()
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

// MARK: - Anchor (stores NSView reference for on-demand screen frame lookup)

/// Holds a weak reference to the anchor NSView so we can query screen position at click time.
final class AnchorViewRef {
    weak var view: NSView?

    func windowLevel() -> NSWindow.Level? {
        view?.window?.level
    }

    func screenFrame() -> NSRect? {
        guard let view, let window = view.window else { return nil }

        // Our NSView may have zero bounds if the SwiftUI bridge doesn't resize it.
        // Fall back to the superview (the SwiftUI bridge container) which has the correct frame.
        let refView: NSView
        if view.bounds.width > 0 {
            refView = view
        } else if let superview = view.superview, superview.bounds.width > 0 {
            refView = superview
        } else {
            return nil
        }

        let boundsInWindow = refView.convert(refView.bounds, to: nil)
        let rect = window.convertToScreen(boundsInWindow)
        return rect.width > 0 ? rect : nil
    }
}

struct DropdownAnchor: NSViewRepresentable {
    let ref: AnchorViewRef

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Track container size so bounds are non-zero
        view.autoresizingMask = [.width, .height]
        ref.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        ref.view = nsView
    }
}

// MARK: - Dropdown

struct RemarcDropdown<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let labelFor: (T) -> String
    var trailingAccessoryFor: ((T, ColorScheme) -> AnyView?)? = nil
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var anchorRef = AnchorViewRef()

    var body: some View {
        Button {
            if isOpen {
                DropdownPanelController.shared.dismiss()
            } else {
                showDropdown()
            }
        } label: {
            HStack(spacing: 4) {
                Text(labelFor(selection))
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let accessory = trailingAccessoryFor?(selection, colorScheme) {
                    accessory
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chevronColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

    private func showDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        isOpen = true
        let cs = colorScheme
        let trailingClosure = trailingAccessoryFor

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: width,
            colorScheme: cs,
            onDismiss: { isOpen = false }
        ) {
            DropdownOptionsPanel(
                options: options,
                currentSelection: selection,
                labelFor: labelFor,
                trailingAccessoryFor: trailingClosure,
                colorScheme: cs,
                width: width
            ) { option in
                selection = option
                DropdownPanelController.shared.dismiss()
            }
        }
    }

    private var backgroundColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.12)
        } else if isHovered {
            return .primary.opacity(0.10)
        } else {
            return .primary.opacity(0.06)
        }
    }

    private var borderColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.3)
        } else if isHovered {
            return .primary.opacity(0.15)
        } else {
            return .primary.opacity(0.1)
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
}

// MARK: - Options Panel Content

private struct DropdownOptionsPanel<T: Hashable>: View {
    let options: [T]
    let currentSelection: T
    let labelFor: (T) -> String
    let trailingAccessoryFor: ((T, ColorScheme) -> AnyView?)?
    let colorScheme: ColorScheme
    let width: CGFloat
    let onSelect: (T) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                OptionRow(
                    label: labelFor(option),
                    trailingAccessory: trailingAccessoryFor?(option, colorScheme),
                    isSelected: option == currentSelection,
                    colorScheme: colorScheme,
                    onSelect: { onSelect(option) }
                )
            }
        }
        .padding(5)
        .frame(width: width)
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

private struct OptionRow: View {
    let label: String
    let trailingAccessory: AnyView?
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
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let trailingAccessory {
                    trailingAccessory
                }
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
