# Remarc

Remarc is a macOS menu bar app for contextual commenting on anything on your screen. Select text in any app, attach a comment to it, and hand your notes to a coding agent - or keep them for yourself.

https://github.com/user-attachments/assets/4393066b-1a22-484c-8703-c55ebef7edbb

- **Comment anywhere.** Select text in any application and attach a comment to that exact selection.
- **Speak instead of typing.** On-device voice dictation with WhisperKit or Parakeet transcription.
- **Screenshot and annotate.** Capture a region, draw on it, redact it, and comment on it.
- **Built for agent workflows.** Comments flow to Claude Code, Codex, and Cursor through an MCP server and plugins, so an agent can pick up your feedback session and address it item by item.
- **Web context.** A [companion Chrome extension](https://remarc.app/chrome-extension/) captures the page URL and element context when you comment on web content.
- **Private by default.** No accounts, no telemetry, no server. Comments live in a local JSON file on your Mac.

## Install

Download the latest signed and notarized build:

- [remarc.app/download](https://remarc.app/download)
- or grab `Remarc.zip` from [GitHub Releases](https://github.com/metedata/Remarc/releases/latest)
- [Install the companion Chrome extension](https://remarc.app/chrome-extension/) for web context in Chrome and other Chromium browsers.

Requires macOS 14.0 (Sonoma) or later. The app updates itself via Sparkle.

## Build from source

Prerequisites: Xcode 26 or later.

```bash
git clone https://github.com/metedata/Remarc.git
cd Remarc/app
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc \
  -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
open DerivedData/Build/Products/Debug/Remarc.app
```

Release builds are signed with a Developer ID certificate and notarized through the [release workflow](.github/workflows/release.yml); see [RELEASING.md](RELEASING.md).

## Repository layout

| Path | Contents |
|------|----------|
| `app/` | The macOS app (SwiftUI + AppKit, Swift 6) |
| `mcp/` | Vendored MCP server artifact + agent skill, bundled into the app |
| `extension/` | Chrome extension for web page context |
| `website/` | remarc.app site and launch router (Cloudflare Workers + static assets) |
| `docs-site/` | docs.remarc.app end-user documentation (Astro Starlight) |
| `docs/` | Design docs and historical planning notes |

The MCP server's source of truth lives in the [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins) repository, which also hosts the Claude Code and Codex plugins. This repo vendors the built artifact.

## Tech stack

Swift 6, SwiftUI + AppKit, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, [WhisperKit](https://github.com/argmaxinc/WhisperKit) and [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device transcription, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), and the Model Context Protocol for agent integrations.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

## Security

To report a vulnerability, please see [SECURITY.md](SECURITY.md). Do not open a public issue for security problems.

## License

Remarc is released under the [MIT License](LICENSE).

The Remarc name, logo, and app icon belong to Metedata LLC and are not covered by the MIT license. Third-party software notices are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). If you distribute a fork, ship it under a different name and icon.
