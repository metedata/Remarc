import SwiftUI

@available(macOS 26, *)
struct CritModeOnboardingView: View {
    let onProceed: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dontShowAgain = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        CritModeHeader(onClose: onCancel)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color.remarcPrimary(for: colorScheme),
                    Color.remarcPrimary(for: colorScheme).opacity(0.6)
                )
                .symbolEffect(.variableColor.iterative.reversing, isActive: true)

            VStack(spacing: 8) {
                Text("Voice Critique")
                    .font(.system(size: 18, weight: .semibold))

                Text("Speak your feedback and Remarc turns it into separate comment cards.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.6 : 0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: dontShowAgain ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(dontShowAgain ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.55))
                    Text("Don't show again")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            .buttonStyle(.plain)

            Button {
                if dontShowAgain {
                    SettingsManager.shared.hasSeenCritModeOnboarding = true
                }
                onProceed()
            } label: {
                Text("Start Recording")
            }
            .buttonStyle(BrandCTAButtonStyle(colorScheme: colorScheme))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
