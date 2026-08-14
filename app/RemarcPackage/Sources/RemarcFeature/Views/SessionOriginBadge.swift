import SwiftUI

/// The small mark beside a session name saying which agent created it.
///
/// One component rather than a branch at each call site: the session bar and
/// the composer's picker both show this, and they had drifted into two copies
/// of the same hardcoded Claude logo - so a Codex session was rendered with
/// Anthropic's mark in both places.
///
/// This reports provenance, not whether an agent is attached right now. Live
/// pairing lives in the session markers; see `WakeReachability`.
struct SessionOriginBadge: View {
    let origin: SessionOrigin

    /// Matches the type metrics at both call sites.
    private let side: CGFloat = 10

    var body: some View {
        switch origin {
        case .manual:
            EmptyView()

        case .claudeCode:
            Image("ClaudeLogo")
                .resizable()
                .renderingMode(.template)
                .frame(width: side, height: side)
                .foregroundStyle(Color.claudeMarkOrange)
                .help("Created by Claude Code")
                .accessibilityLabel("Created by Claude Code")

        case .codex:
            // Template-rendered, so it takes the foreground colour rather than
            // the mark's own black. Codex has no brand tint to match the way
            // Claude Code has orange, and a fixed black would vanish in dark
            // mode - so it follows the text instead.
            Image("CodexLogo")
                .resizable()
                .renderingMode(.template)
                .frame(width: side, height: side)
                .foregroundStyle(.primary.opacity(0.75))
                .help("Created by Codex")
                .accessibilityLabel("Created by Codex")

        case .omp:
            // OMP's dark rounded square and gradient pi are one full-colour
            // mark. Template rendering would collapse it into a solid block.
            Image("OMPLogo")
                .resizable()
                .renderingMode(.original)
                .frame(width: side, height: side)
                .help("Created by OMP")
                .accessibilityLabel("Created by OMP")
        }
    }
}
