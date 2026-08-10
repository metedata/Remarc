# Contributing to Remarc

Thanks for your interest in improving Remarc.

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 26 or later

## Build and run

```bash
git clone https://github.com/metedata/Remarc.git
cd Remarc/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc \
  -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
open DerivedData/Build/Products/Debug/Remarc.app
```

Debug builds log to `/tmp/remarc_debug.log` (release builds log to `~/Library/Logs/Remarc/remarc_debug.log`).

If the build fails with a signing error because you are not a member of the project's Apple Developer team, build with ad-hoc signing instead:

```bash
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc \
  -configuration Debug -derivedDataPath "$(pwd)/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Note that macOS ties Accessibility and Microphone grants to the signing identity, so ad-hoc builds may re-prompt for permissions after rebuilds.

Remarc needs Accessibility permission to read text selections, and Microphone plus Speech Recognition permissions for dictation. macOS will prompt on first use; grant them for the Debug build you just launched.

## Project structure

| Path | Contents |
|------|----------|
| `app/Remarc/` | App target: entry point, Info.plist, entitlements |
| `app/RemarcPackage/Sources/RemarcFeature/` | Nearly all app code (services, views, models) |
| `app/Config/Shared.xcconfig` | Version numbers and deployment target |
| `mcp/vendor/` | Vendored MCP server artifact (built in [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins); do not edit by hand - the build verifies its sha256) |
| `extension/` | Chrome extension |
| `tests/` | Test suite |

## Code style

- Swift 6 with strict concurrency; keep new code `@MainActor`-correct rather than sprinkling `@unchecked Sendable`.
- Colors come from the token system in `app/RemarcPackage/Sources/RemarcFeature/Views/Colors.swift` (`remarcPrimary`, `remarcAccent`, ...). Never hardcode hex values in views; every token adapts to light and dark mode.
- Tooltips use SwiftUI's `.help()` modifier, matching the rest of the app.
- No em dashes in user-facing strings (UI copy, release notes); use hyphens.

## Pull requests

Before opening a PR:

1. The app builds without warnings introduced by your change.
2. You launched the Debug build and exercised the affected flow.
3. UI changes include a screenshot or short recording.
4. Keep PRs focused; unrelated cleanups belong in their own PR.

CI builds every PR without code signing; it must pass.

## Reporting bugs

Use the bug report issue template. Attaching the tail of the debug log (`~/Library/Logs/Remarc/remarc_debug.log` for release builds, `/tmp/remarc_debug.log` for Debug builds) helps a lot; scrub anything you consider private first.
