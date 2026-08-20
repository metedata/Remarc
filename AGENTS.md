# Remarc

macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Bundle ID: `com.metepolat.Remarc`
- Min macOS: 14.0 (`MACOSX_DEPLOYMENT_TARGET` in `app/Config/Shared.xcconfig` is the source of truth), Swift 6.0+, LSUIElement (no dock icon)
- Build: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`
- Debug log: `/tmp/remarc_debug.log` (Debug builds only; release builds write no log file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`)
- Data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)

**MANDATORY: After every successful build, you MUST relaunch Remarc.** The user cannot verify changes otherwise. Do this every single time, no exceptions:
1. Build with `-derivedDataPath "$(pwd)/DerivedData"` (deterministic output path — no grep/find needed)
2. Relaunch: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Worktree Builds

When building from worktrees, always verify the correct DerivedData path and binary location before launching. Use absolute paths instead of $PWD in build commands.

## UI Work

When the user describes a UI bug, confirm WHICH specific component/view they mean before editing. Ask clarifying questions if the target is ambiguous (e.g., 'comment cards' vs 'session chips').

## Development

### Contribution Attribution

Use `Mete Polat <20049378+metedata@users.noreply.github.com>` as the author of repository and automated release commits and as the tagger of annotated tags. Automated commits must use the same identity as committer. Do not add `Co-authored-by` or equivalent attribution for bots, models, agents, or anyone else. Attribute another contributor only when Mete explicitly requests it.

### Git Worktrees — MANDATORY

**All code changes MUST be made in a git worktree, not on main.** Always create a worktree before starting any feature, bugfix, or refactor. The only exceptions are edits to root config files (AGENTS.md, scripts/, .Codex/).

Worktrees go in `.worktrees/` (gitignored). Use `git worktree add .worktrees/<name> -b <branch>` for isolated feature work.

**Build path in worktrees:** Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` (variable) — `$PWD` can resolve incorrectly in subshells and worktree contexts.

### Crit Mode / Microphone Capture

When building from worktrees (or after nuking DerivedData), macOS TCC microphone permissions get fragmented across binary paths. The audio tap silently produces 0 buffers without any error. **Fix: nuke DerivedData + reset TCC before relaunch:**

```bash
rm -rf app/DerivedData
# rebuild...
tccutil reset Microphone com.metepolat.Remarc
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

The user must grant mic access when macOS prompts after the reset. Do this whenever audio capture stops working (0 buffers in debug log).

### Color System

All brand colors and gradients are defined in `Views/Colors.swift` as `Color` extensions. When making color-related changes:

- **Use `remarc*` tokens** (`remarcPrimary`, `remarcSecondary`, `remarcAccent`, etc.) — never hardcode brand hex values in views
- **All tokens take `colorScheme`** — they adapt for light/dark mode automatically
- **Popover background** uses `remarcBackgroundGradient(for:)` — layered EllipticalGradients with `.plusLighter` blend over a darkened base. Do not add `.background(.regularMaterial)` to SwiftUI — the VEV provides that
- **Quote references** use a 2pt indigo left border via `.overlay(alignment: .leading)` — keep this consistent across CommentCardView, CommentEditorView, and CommentInputView
- **Buttons** use `remarcBrandGradient` for primary CTAs and `remarcPrimary` for accent text

### Research During Brainstorming & Planning

When brainstorming features or writing implementation plans, **always do online research** (WebSearch, WebFetch) and **check Context7 docs** for relevant Apple frameworks and libraries before proposing approaches. API availability, deprecation status, and permission requirements change frequently — don't rely on training data alone.

### Architecture

- `app/RemarcPackage/` — Swift Package with all app source
- `app/RemarcPackage/Sources/RemarcFeature/` — Main feature module
  - `Views/` — SwiftUI views and AppKit window controllers
  - `Services/` — PersistenceManager, SelectionMonitor, ExportManager, etc.
- `scripts/` — Automation scripts
- `tools/ax-inspect/` — Accessibility inspection CLI (standalone SPM package)
