import AppKit
import SwiftUI

// MARK: - Panel

@available(macOS 26, *)
private class DictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            DictationPillController.shared.cancel()
        }
    }
}

// MARK: - Controller
// Uses NSVisualEffectView + maskImage for clean material rendering.
// Appear/dismiss uses window-level alphaValue animation (no SwiftUI blur — VEV clips it).

@available(macOS 26, *)
@MainActor
final class DictationPillController: ObservableObject {
    static let shared = DictationPillController()

    private var panel: DictationPillPanel?
    private var hostingView: NSHostingView<DictationPillView>?

    @Published var errorMessage: String?
    private var errorDismissTask: Task<Void, Never>?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { createPanel() }
        positionCenterBottom()

        guard let panel else { return }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        debugLog("DictationPillController: shown")
    }

    func dismiss() {
        errorDismissTask?.cancel()
        errorMessage = nil

        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) {
            panel.orderOut(nil)
            panel.alphaValue = 1
            debugLog("DictationPillController: dismissed")
        }
    }

    func showError(_ message: String) {
        if panel == nil || !(panel?.isVisible ?? false) {
            show()
        }
        updateSizeForError()
        errorMessage = message
        DictationSounds.playError()
        shakePanel()

        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.errorMessage = nil
            self.dismiss()
        }
    }

    private func shakePanel() {
        guard let panel else { return }
        let origin = panel.frame.origin
        let offsets: [(CGFloat, Double)] = [
            (8, 0.05), (-6, 0.05), (4, 0.05), (-2, 0.05), (0, 0.05)
        ]
        var delay: Double = 0
        for (offset, duration) in offsets {
            let capturedDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + capturedDelay) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    panel.animator().setFrameOrigin(NSPoint(x: origin.x + offset, y: origin.y))
                }
            }
            delay += duration
        }
    }

    private func updateSizeForError() {
        resizePanel(to: DictationPillView.errorWidth, animated: false)
    }

    func cancel() {
        // Dismiss first so the pill doesn't shrink before fading out
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            DictationService.shared.cancelRecording()
        }
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let pillView = DictationPillView()
        let hosting = NSHostingView(rootView: pillView)
        hosting.sizingOptions = [.intrinsicContentSize]

        let panelHeight = DictationPillView.pillHeight
        let panelWidth: CGFloat = DictationPillView.holdWidth

        let panel = DictationPillPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        // NSVisualEffectView as contentView with pill-shaped mask
        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.maskImage = Self.pillMaskImage(size: NSSize(width: panelWidth, height: panelHeight))
        panel.contentView = vev

        // Pin hosting view via Auto Layout
        hosting.translatesAutoresizingMaskIntoConstraints = false
        vev.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: vev.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: vev.bottomAnchor),
        ])

        self.hostingView = hosting
        self.panel = panel
    }

    func updateSize(animated: Bool = false) {
        let service = DictationService.shared
        let width = (service.persistentMode && service.state == .recording)
            ? DictationPillView.persistentWidth
            : DictationPillView.holdWidth
        resizePanel(to: width, animated: animated)
    }

    func updateSizeForWarmup() {
        resizePanel(to: DictationPillView.warmupWidth, animated: true)
    }

    /// Unified panel resize: updates frame, mask image, and shadow.
    private func resizePanel(to newWidth: CGFloat, animated: Bool) {
        guard let panel, let vev = panel.contentView as? NSVisualEffectView else { return }
        let newHeight: CGFloat = DictationPillView.pillHeight
        let newSize = NSSize(width: newWidth, height: newHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let oldFrame = panel.frame
                let newX = oldFrame.midX - newWidth / 2
                panel.animator().setFrame(
                    NSRect(x: newX, y: oldFrame.origin.y, width: newWidth, height: newHeight),
                    display: true
                )
            }
        } else {
            panel.setContentSize(newSize)
            positionCenterBottom()
        }
        vev.maskImage = Self.pillMaskImage(size: newSize)
        panel.invalidateShadow()
    }

    // MARK: - Positioning

    private func positionCenterBottom() {
        guard let panel else { return }
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.minY + 60

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Pill Mask

    private static func pillMaskImage(size: NSSize) -> NSImage {
        .roundedRectMask(cornerRadius: size.height / 2)
    }
}

// MARK: - DictationPillView

@available(macOS 26, *)
struct DictationPillView: View {
    @ObservedObject private var service = DictationService.shared
    @ObservedObject private var controller = DictationPillController.shared
    @Environment(\.colorScheme) private var colorScheme

    // Hold mode: just the indicator (spinner/waveform) — compact
    // Persistent mode: indicator + divider + stop + cancel — wider
    // Warmup mode: spinner + "Preparing..." label + cancel (only after delay)
    static let holdWidth: CGFloat = 80
    static let persistentWidth: CGFloat = 170
    static let warmupWidth: CGFloat = 240
    static let pillHeight: CGFloat = 44
    static let errorWidth: CGFloat = 220

    /// Only show the warmup label after a delay so quick loads don't flash it.
    @State private var showWarmupLabel = false
    @State private var warmupDelayTask: Task<Void, Never>?
    private static let warmupLabelDelay: TimeInterval = 1.5

    private let isPersistent: Bool

    init() {
        // Snapshot persistent state at creation — layout driven by controller updateSize()
        self.isPersistent = false
    }

    var body: some View {
        Group {
            if service.state == .warmingUp {
                warmupLayout
            } else if service.persistentMode && service.state == .recording {
                persistentLayout
            } else {
                holdLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(brandedBackground)
        .overlay {
            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
            }
        }
        .onChange(of: service.persistentMode) { _, _ in
            DictationPillController.shared.updateSize(animated: true)
        }
        .onChange(of: service.state) { _, newState in
            warmupDelayTask?.cancel()
            if newState == .warmingUp {
                // Start timer — only show warmup label if warmup takes a while
                showWarmupLabel = false
                warmupDelayTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.warmupLabelDelay))
                    guard !Task.isCancelled, service.state == .warmingUp else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showWarmupLabel = true
                    }
                    DictationPillController.shared.updateSizeForWarmup()
                }
            } else {
                if showWarmupLabel {
                    showWarmupLabel = false
                }
                // Resize when transitioning out of warmup or in persistent mode
                DictationPillController.shared.updateSize(animated: true)
            }
        }
    }

    // MARK: - Layouts

    private var holdLayout: some View {
        stateIndicator
    }

    private var warmupLayout: some View {
        HStack(spacing: 8) {
            if showWarmupLabel {
                Spacer()
            }

            ProgressView()
                .controlSize(.small)

            if showWarmupLabel {
                Text("Preparing model…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .transition(.opacity)

                Spacer()

                PillActionButton(
                    icon: "xmark",
                    iconSize: 8,
                    size: 24,
                    style: .ghost(colorScheme),
                    label: "Cancel"
                ) {
                    DictationPillController.shared.cancel()
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, showWarmupLabel ? 12 : 0)
    }

    private var persistentLayout: some View {
        HStack(spacing: 0) {
            PillActionButton(
                icon: "stop.fill",
                iconSize: 8,
                size: 24,
                style: .brand(colorScheme),
                label: "Done"
            ) {
                Task { await GlobalHotkey.shared.stopDictationAndPaste() }
            }

            Spacer()

            stateIndicator

            Spacer()

            PillActionButton(
                icon: "xmark",
                iconSize: 8,
                size: 24,
                style: .ghost(colorScheme),
                label: "Cancel"
            ) {
                DictationPillController.shared.cancel()
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - State Indicator

    @ViewBuilder
    private var stateIndicator: some View {
        switch service.state {
        case .idle:
            EmptyView()
        case .warmingUp:
            ProgressView()
                .controlSize(.small)
        case .recording:
            MiniWaveformView(levels: service.audioLevels, isHovered: false)
        case .processing:
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Branded Background
    // Always shows a subtle brand tint. Gets more vibrant and audio-reactive when recording.

    private var brandedBackground: some View {
        let level = CGFloat(service.audioLevels.last ?? 0)
        let intensity = min(level * 32, 1.0)
        let isDark = colorScheme == .dark
        let isRecording = service.state == .recording

        // Base: subtle brand tint always visible
        let baseAlpha = isDark ? 0.12 : 0.08
        // Recording: stronger + audio-reactive
        let activeAlpha = isRecording ? (baseAlpha + 0.15 * intensity) : baseAlpha

        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.remarcBrandIndigo.opacity(activeAlpha * 1.4),
                        Color.remarcBrandViolet.opacity(activeAlpha * 0.8)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .blendMode(.plusLighter)
            .animation(.easeOut(duration: 0.1), value: intensity)
            .animation(.easeInOut(duration: 0.3), value: isRecording)
    }
}

// MARK: - Pill Action Button (with hover label)

@available(macOS 26, *)
private struct PillActionButton: View {
    enum Style {
        case brand(ColorScheme)
        case ghost(ColorScheme)

        var foreground: Color {
            switch self {
            case .brand: return .white
            case .ghost(let cs):
                return cs == .dark ? .white.opacity(0.5) : .black.opacity(0.45)
            }
        }
    }

    let icon: String
    let iconSize: CGFloat
    let size: CGFloat
    let style: Style
    let label: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(style.foreground)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(backgroundFill)
                        .shadow(color: shadowColor, radius: 4)
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.06 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .overlay(alignment: .bottom) {
            if isHovered {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .offset(y: size / 2 + 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var backgroundFill: AnyShapeStyle {
        switch style {
        case .brand(let cs):
            AnyShapeStyle(Color.remarcBrandGradient(for: cs))
        case .ghost(let cs):
            AnyShapeStyle(cs == .dark
                ? Color.white.opacity(isHovered ? 0.14 : 0.08)
                : Color.black.opacity(isHovered ? 0.10 : 0.06))
        }
    }

    private var shadowColor: Color {
        switch style {
        case .brand(let cs):
            isHovered ? Color.remarcPrimary(for: cs).opacity(0.4) : .clear
        case .ghost:
            .clear
        }
    }
}
