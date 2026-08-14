# Remarc

Remarc is the feedback layer between you and your coding agent. Point at anything on your Mac: text, a screenshot, or a web element. Talk through a review or jot down a quick note. Remarc keeps the relevant context with each comment so your agent can take it from there.

https://github.com/user-attachments/assets/4393066b-1a22-484c-8703-c55ebef7edbb

## How it works

### 1. Comment on anything

Remarc runs from the menu bar, ready whenever you spot something worth changing. Comment on selected text, screenshots, web elements, or speak your feedback. Remarc keeps the original selection, screenshot, web context, or recording with your note, so your agent works from what you saw instead of a paraphrase.

#### Text comments

Select text in any app and attach a comment to that exact selection. Remarc saves the quote and source app with your note. The [text comments guide](https://docs.remarc.app/basics/commenting-on-selections/) covers the tooltip, keyboard shortcut, and app exclusions.

#### Screenshot comments

Grab any region of the screen, adjust the selection, then add arrows, shapes, text, counters, blur, or pixelation. The screenshot stays attached to the comment, and you can reopen it to add or edit annotations. Read about [screenshot capture](https://docs.remarc.app/screenshots/capturing/) and [annotation and redaction](https://docs.remarc.app/screenshots/annotating-and-redacting/).

#### Web element comments

The [companion Chrome extension](https://remarc.app/chrome-extension/) captures the page URL, selected element or page region, CSS, layout, accessibility data, and React component details when available. The captured web context stays with the comment. Installation and capture shortcuts are in the [extension guide](https://docs.remarc.app/chrome-extension/).

#### Voice comments and Crit Mode

On macOS 26 or later, dictate one comment or record a longer review in [Crit Mode](https://docs.remarc.app/voice/voice-comments-and-crit-mode/). Crit Mode transcribes the recording and splits it into separate comment cards. Apple Speech, WhisperKit, and Parakeet all run transcription on your Mac.

#### Quick Notes

Open a [Quick Note](https://docs.remarc.app/basics/quick-notes/) when there is nothing to select or capture. It creates a standalone comment for a thought, task, or piece of feedback.

### 2. Your agent picks up the comments

Comments land in a session. Once you connect an agent, it can read each one with the attached context and work through the list. You do not have to rebuild that context in a separate prompt.

#### Sessions keep each review together

Group comments into [sessions](https://docs.remarc.app/basics/sessions/) by review, project, or agent conversation. The permanent Inbox catches anything you do not file elsewhere, and connected agents can create sessions for their own conversations.

#### MCP and plugins carry the context

Claude Code and Codex connect through plugins from the public [Remarc agent integrations repository](https://github.com/metedata/remarc-agent-plugins), Cursor is configured by the app, and Claude Desktop or another MCP client can connect manually. Every supported client gets the same context and MCP tools for reading comments, managing sessions, and resolving work. The [agent integrations guide](https://docs.remarc.app/agents/overview/) covers each setup path.

#### Statuses close the loop

Each comment can move through Open, Handed Off, In-Progress, and Resolved. Agents can update the status as they work and leave a resolution summary when they finish. Deleted comments go to searchable [History](https://docs.remarc.app/basics/statuses-and-history/) instead of disappearing.

#### Copy, export, or automate the handoff

Copy a session into an agent prompt, paste it into the app you are using, or [export it as Markdown or JSON](https://docs.remarc.app/basics/export-comments/) with control over references and metadata. You can also send comment events to automation tools through [webhooks](https://docs.remarc.app/agents/webhooks/).

#### Local until you hand it off

Comments and screenshots stay on your Mac unless you hand them to an agent or send them through a webhook you configured. There are no accounts or telemetry. The [data and privacy guide](https://docs.remarc.app/reference/data-and-privacy/) explains what is stored and which features use the network.

## Documentation

Read the [full Remarc documentation](https://docs.remarc.app/getting-started/what-is-remarc/) for setup and feature guides. Useful starting points include [installation](https://docs.remarc.app/getting-started/installation/), [permissions](https://docs.remarc.app/getting-started/permissions/), [agent integrations](https://docs.remarc.app/agents/overview/), [keyboard shortcuts](https://docs.remarc.app/reference/keyboard-shortcuts/), and [troubleshooting](https://docs.remarc.app/reference/troubleshooting/).

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

## Support

If Remarc is useful to you, you can [Buy Me a Coffee](https://buymeacoffee.com/metedata) to support its continued development. Remarc remains free and open source.

## Security

To report a vulnerability, please see [SECURITY.md](SECURITY.md). Do not open a public issue for security problems.

## License

Remarc is released under the [MIT License](LICENSE).

The Remarc name, logo, and app icon belong to Metedata LLC and are not covered by the MIT license. Third-party software notices are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). If you distribute a fork, ship it under a different name and icon.
