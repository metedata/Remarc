import SwiftUI

@available(macOS 26, *)
struct AudioWaveformView: View {
    let levels: [Float]
    let barCount: Int

    @Environment(\.colorScheme) private var colorScheme

    init(levels: [Float], barCount: Int = 48) {
        self.levels = levels
        self.barCount = barCount
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                drawWaveform(context: context, size: size)
            }
        }
        .frame(height: 80)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 2
        let totalBarWidth = barWidth + barSpacing
        let actualBarCount = min(barCount, Int(size.width / totalBarWidth))
        let totalWidth = CGFloat(actualBarCount) * totalBarWidth - barSpacing
        let startX = (size.width - totalWidth) / 2
        let centerY = size.height / 2
        let maxBarHeight = size.height * 0.8

        // Sample levels to match bar count
        let sampledLevels = sampleLevels(count: actualBarCount)

        let primaryColor = Color.remarcPrimary(for: colorScheme)
        let accentColor = Color.remarcAccent(for: colorScheme)

        for i in 0..<actualBarCount {
            let level = sampledLevels[i]
            // Normalize and apply minimum height
            let scaled = min(max(CGFloat(level) * 16, 0.0), 1.0)
            let normalized = max(pow(scaled, 0.6), 0.05)
            let barHeight = max(normalized * maxBarHeight, 4)

            let x = startX + CGFloat(i) * totalBarWidth
            let rect = CGRect(
                x: x,
                y: centerY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )

            // Gradient from primary to accent based on position
            let t = CGFloat(i) / CGFloat(max(actualBarCount - 1, 1))
            let color = interpolateColor(from: primaryColor, to: accentColor, t: t)

            let path = RoundedRectangle(cornerRadius: barWidth / 2)
                .path(in: rect)
            context.fill(path, with: .color(color.opacity(0.6 + normalized * 0.4)))
        }
    }

    private func sampleLevels(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }

        // Take the most recent levels, padded if needed
        if levels.count >= count {
            return Array(levels.suffix(count))
        } else {
            let padding = Array(repeating: Float(0), count: count - levels.count)
            return padding + levels
        }
    }

    private func interpolateColor(from: Color, to: Color, t: CGFloat) -> Color {
        // Simple blend using opacity overlay approach
        // For brand colors, mix between indigo and violet
        let clamped = min(max(t, 0), 1)
        return Color(
            red: lerp(from: 0.388, to: 0.545, t: clamped),
            green: lerp(from: 0.400, to: 0.361, t: clamped),
            blue: lerp(from: 0.945, to: 0.965, t: clamped)
        )
    }

    private func lerp(from: Double, to: Double, t: CGFloat) -> Double {
        from + (to - from) * Double(t)
    }
}
