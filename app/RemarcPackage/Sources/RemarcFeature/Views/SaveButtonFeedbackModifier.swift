import SwiftUI

/// Repeatable save-button feedback shared by both composer implementations.
/// Reduce Motion replaces displacement with a static error outline.
struct SaveButtonFeedbackModifier: ViewModifier {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakePhase: CGFloat = 0
    @State private var showsErrorOutline = false
    @State private var feedbackGeneration = 0

    func body(content: Content) -> some View {
        content
            .modifier(HorizontalShakeEffect(animatableData: reduceMotion ? 0 : shakePhase))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.red.opacity(showsErrorOutline ? 0.9 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .onChange(of: trigger) { oldValue, newValue in
                guard newValue != oldValue else { return }
                guard newValue > 0 else {
                    // The long-lived comment composer reuses this modifier across
                    // drafts. Clear any in-flight Reduce Motion outline instead of
                    // carrying an old validation state into the replacement draft.
                    feedbackGeneration = newValue
                    shakePhase = 0
                    showsErrorOutline = false
                    return
                }
                showFeedback(for: newValue)
            }
    }

    private func showFeedback(for generation: Int) {
        feedbackGeneration = generation
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) {
                showsErrorOutline = true
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) {
                shakePhase += 1
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard feedbackGeneration == generation else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                showsErrorOutline = false
            }
        }
    }
}

private struct HorizontalShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    private let amplitude: CGFloat = 3
    private let oscillations = 3

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amplitude * sin(animatableData * .pi * CGFloat(oscillations))
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
