import SwiftUI

@available(macOS 26, *)
struct CritModeRecordingView: View {
    @ObservedObject var service: CritModeService
    let onCancel: () -> Void
    let onComplete: ([Comment]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isCompleting = false
    @State private var pendingComments: [Comment]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch service.state {
            case .preparingModel:
                preparingView
            case .recording(let startTime):
                recordingContent(startTime: startTime)
            case .processing:
                if isCompleting {
                    completingView
                } else {
                    processingView
                }
            case .idle:
                if isCompleting {
                    completingView
                } else {
                    processingView
                }
            }
        }
    }

    private var header: some View {
        CritModeHeader(onClose: onCancel)
    }

    // MARK: - Preparing

    private var preparingView: some View {
        RemarcLogoLoadingView(mode: .preparing)
    }

    // MARK: - Recording Content

    private func recordingContent(startTime: Date) -> some View {
        // Audio-reactive values for mesh animation
        let fast = min(max(CGFloat(service.smoothedLevel) * 16, 0.0), 1.0)
        let slow = min(max(CGFloat(service.slowSmoothedLevel) * 10, 0.0), 1.0)

        return VStack(spacing: 0) {
            Spacer()

            AudioWaveformView(levels: service.audioLevels)
                .padding(.horizontal, 24)

            ElapsedTimerView(startTime: startTime)
                .padding(.top, 12)

            Text("Speak your critique — each point becomes a comment")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .padding(.top, 6)

            Spacer()

            FloatingActionButton(icon: "stop.fill") {
                Task {
                    do {
                        let comments = try await service.stopRecording()
                        if comments.isEmpty {
                            ToastManager.shared.show("No speech detected")
                            onCancel()
                            return
                        }
                        pendingComments = comments
                        isCompleting = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                            onComplete(pendingComments ?? [])
                        }
                    } catch {
                        debugLog("CritModeRecordingView: Stop failed: \(error)")
                        onCancel()
                    }
                }
            }
            .help("Stop recording")
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            audioReactiveMeshBackground(fast: fast, slow: slow)
        }
    }

    // MARK: - Audio-Reactive Mesh Background

    private func audioReactiveMeshBackground(fast: CGFloat, slow: CGFloat) -> some View {
        let isDark = colorScheme == .dark
        let baseAlpha = isDark ? 0.30 : 0.20
        let activeAlpha = baseAlpha + 0.25 * slow

        // Brand colors at varying intensities
        let indigo = Color.remarcBrandIndigo
        let violet = Color.remarcBrandViolet
        let clear = Color.clear

        // Interior mesh points shift with audio — creates organic warping
        let drift = Float(0.03 * fast)
        let sway = Float(0.02 * slow)

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                // Top row — fixed edges
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                // Middle row — center point drifts with audio
                [0.0, 0.5], [0.5 + drift, 0.5 - sway], [1.0, 0.5],
                // Bottom row — fixed edges
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: [
                // Top: indigo wash top-left, fading right
                indigo.opacity(activeAlpha * 1.4), clear, clear,
                // Middle: subtle glow reacting to voice
                indigo.opacity(activeAlpha * 0.5), violet.opacity(activeAlpha * (0.6 + 0.8 * fast)), clear,
                // Bottom: violet wash bottom-right
                clear, violet.opacity(activeAlpha * 0.4), violet.opacity(activeAlpha * 1.0)
            ]
        )
        .blendMode(.plusLighter)
        .animation(.easeOut(duration: 0.15), value: fast)
        .animation(.easeInOut(duration: 0.4), value: slow)
    }

    // MARK: - Processing

    private var processingView: some View {
        RemarcLogoLoadingView(mode: .processing)
    }

    // MARK: - Completing (fill animation before dismiss)

    private var completingView: some View {
        RemarcLogoLoadingView(mode: .completing)
    }
}

// MARK: - Crit Mode Header (shared by onboarding + recording)

@available(macOS 26, *)
struct CritModeHeader: View {
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                Text("Crit Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Elapsed Timer

@available(macOS 26, *)
private struct ElapsedTimerView: View {
    let startTime: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startTime)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
                .font(.system(size: 24, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.6))
        }
    }
}
