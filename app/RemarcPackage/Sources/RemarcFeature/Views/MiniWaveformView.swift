import SwiftUI

@available(macOS 26, *)
struct MiniWaveformView: View {
    let levels: [Float]
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        let barColor = Color.remarcPrimary(for: colorScheme)
        let recentLevels = Array(levels.suffix(barCount))
        // Adaptive normalization: scale relative to the recent peak level.
        // The loudest recent sample maps to full height, others are relative.
        let peak = CGFloat(levels.suffix(48).max() ?? 0)
        let reference = max(peak, 0.003) // floor prevents noise amplification in silence

        ZStack {
            // Stop icon (visible on hover)
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 10, height: 10)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)

            // Waveform bars (hidden on hover)
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let level = index < recentLevels.count ? CGFloat(recentLevels[index]) : 0
                    let normalized = min(level / reference, 1.0)
                    let height = max(sqrt(normalized) * 16, 4)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barColor)
                        .frame(width: barWidth, height: height)
                }
            }
            .opacity(isHovered ? 0 : 1)
            .scaleEffect(isHovered ? 0.7 : 1)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
