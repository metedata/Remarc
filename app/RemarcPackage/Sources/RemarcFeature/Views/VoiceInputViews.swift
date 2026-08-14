import SwiftUI

// MARK: - Shared Voice Input Views (macOS 26+)

/// Appends transcribed text to a string, separating with a space if non-empty.
func appendVoiceText(_ text: String, to target: inout String) {
    if target.isEmpty {
        target = text
    } else {
        target += " " + text
    }
}

/// Save button that reacts to VoiceInputService state — shows spinner when warming up,
/// waveform when recording, and the normal Save button otherwise.
@available(macOS 26, *)
struct VoiceAutoSaveButtonState {
    let countdownActive: Bool
    let progress: Double
    let remainingSeconds: Int
    let feedbackTrigger: Int
    let onHoverChanged: (Bool) -> Void

    init(
        countdownActive: Bool = false,
        progress: Double = 0,
        remainingSeconds: Int = 0,
        feedbackTrigger: Int = 0,
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.countdownActive = countdownActive
        self.progress = progress
        self.remainingSeconds = remainingSeconds
        self.feedbackTrigger = feedbackTrigger
        self.onHoverChanged = onHoverChanged
    }
}

@available(macOS 26, *)
struct VoiceAwareSaveButton: View {
    @ObservedObject private var voiceInput = VoiceInputService.shared
    @Binding var isSaveHovered: Bool
    let colorScheme: ColorScheme
    let onSave: () -> Void
    let appendText: (String) -> Void
    let transcriptionGeneration: UInt64
    let acceptsTranscription: (UInt64) -> Bool
    let autoSaveState: VoiceAutoSaveButtonState

    init(
        isSaveHovered: Binding<Bool>,
        colorScheme: ColorScheme,
        onSave: @escaping () -> Void,
        appendText: @escaping (String) -> Void,
        transcriptionGeneration: UInt64,
        acceptsTranscription: @escaping (UInt64) -> Bool,
        autoSaveState: VoiceAutoSaveButtonState = VoiceAutoSaveButtonState()
    ) {
        _isSaveHovered = isSaveHovered
        self.colorScheme = colorScheme
        self.onSave = onSave
        self.appendText = appendText
        self.transcriptionGeneration = transcriptionGeneration
        self.acceptsTranscription = acceptsTranscription
        self.autoSaveState = autoSaveState
    }

    @State private var isWaveformHovered = false
    private let buttonHeight: CGFloat = 28
    private let buttonMinWidth: CGFloat = 84

    var body: some View {
        Group {
            if voiceInput.state == .idle {
                Button(action: onSave) {
                    HStack(spacing: 6) {
                        if autoSaveState.countdownActive && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            Text("Saving... \(autoSaveState.remainingSeconds)s")
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Text("Save")
                                .font(.system(size: 12, weight: .medium))
                            HStack(spacing: 1) {
                                Image(systemName: "command")
                                Image(systemName: "return")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(minWidth: buttonMinWidth, minHeight: buttonHeight)
                    .background(
                        GeometryReader { geo in
                            Color.remarcBrandGradient(for: colorScheme)
                                .frame(width: geo.size.width * autoSaveState.progress)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    )
                    .background(
                        Color.remarcBrandGradient(for: colorScheme).opacity(
                            autoSaveState.countdownActive ? 0.3 : 1.0
                        ),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .opacity(isSaveHovered || autoSaveState.countdownActive ? 1.0 : 0.85)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isSaveHovered = hovering
                    autoSaveState.onHoverChanged(hovering)
                }
                .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
                .accessibilityIdentifier("remarc.commentInput.submitButton")
                .zIndex(1)
                .transition(.blurReplace)
            } else {
                // Recording mode shell (warmingUp / recording / processing)
                Button(action: {
                    guard voiceInput.state == .recording else { return }
                    let generation = transcriptionGeneration
                    Task {
                        let text = try? await VoiceInputService.shared.stopRecording()
                        if let text, !text.isEmpty, acceptsTranscription(generation) {
                            appendText(text)
                        }
                    }
                }) {
                    Group {
                        if voiceInput.state == .recording {
                            MiniWaveformView(
                                levels: voiceInput.audioLevels,
                                isHovered: isWaveformHovered
                            )
                            .transition(.opacity)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: buttonMinWidth, minHeight: buttonHeight)
                    .background(
                        Color.remarcPrimary(for: colorScheme).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.5), lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in isWaveformHovered = hovering }
                .help(voiceInput.state == .recording ? "Stop recording" : "")
                .zIndex(1)
                .transition(.blurReplace)
            }
        }
        // Keep feedback mounted while the visual button switches between Save,
        // recording, and processing. Otherwise Command-Return can report an
        // invalid Quick Note while this modifier is absent and the shake is lost.
        .modifier(SaveButtonFeedbackModifier(trigger: autoSaveState.feedbackTrigger))
    }
}

/// Mic toggle button — starts or stops voice recording.
@available(macOS 26, *)
struct VoiceMicButton: View {
    @ObservedObject private var voiceInput = VoiceInputService.shared
    @Binding var isMicHovered: Bool
    let appendText: (String) -> Void
    let transcriptionGeneration: UInt64
    let acceptsTranscription: (UInt64) -> Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: toggleRecording) {
            Group {
                if voiceInput.state == .recording {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(isMicHovered ? 1.0 : 0.7))
                        .transition(.opacity)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(isMicHovered ? 0.6 : 0.3))
                        .transition(.opacity)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isMicHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isMicHovered)
        .disabled(voiceInput.state == .warmingUp || voiceInput.state == .processing)
        .help(voiceInput.state == .recording ? "Stop recording" : "Voice input")
    }

    private func toggleRecording() {
        let generation = transcriptionGeneration
        Task {
            if voiceInput.state == .recording {
                let text = try? await voiceInput.stopRecording()
                if let text, !text.isEmpty, acceptsTranscription(generation) {
                    appendText(text)
                }
            } else if voiceInput.state == .idle {
                try? await voiceInput.startRecording()
            }
        }
    }
}

/// Recording overlay — subtle accent border + audio-reactive background glow.
@available(macOS 26, *)
struct VoiceRecordingBorder: View {
    @ObservedObject private var voiceInput = VoiceInputService.shared
    let colorScheme: ColorScheme

    var body: some View {
        let level = CGFloat(voiceInput.audioLevels.last ?? 0)
        let intensity = min(level * 32, 1.0)
        let isDark = colorScheme == .dark
        let indigo = Color.remarcBrandIndigo
        let violet = Color.remarcBrandViolet
        let baseAlpha = isDark ? 0.08 : 0.05
        let activeAlpha = baseAlpha + 0.12 * intensity

        ZStack {
            // Audio-reactive background glow
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            indigo.opacity(activeAlpha * 1.4),
                            violet.opacity(activeAlpha * 0.8)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)

            // Static accent border
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.remarcPrimary(for: colorScheme).opacity(0.5), lineWidth: 1.5)
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: intensity)
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }

    private var isActive: Bool {
        voiceInput.state == .warmingUp || voiceInput.state == .recording
    }
}
