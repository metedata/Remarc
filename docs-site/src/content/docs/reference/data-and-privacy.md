---
title: Data, privacy & updates
description: Where Remarc stores comments and screenshots, exactly what touches the network, and how signed automatic updates work.
---

Everything Remarc captures stays on your Mac. There is no account, no sign-in, and no server holding your comments.

## Where your data lives

Remarc stores all data in `~/Library/Application Support/Remarc/`:

- `comments.json` holds your sessions and comments.
- Screenshots and image attachments are stored as files in the same folder and referenced by comments.

Agents read and update comments through MCP (Model Context Protocol) tools rather than editing the file directly. See the [agents overview](/agents/overview/).

## Voice stays on-device

All three [transcription engines](/voice/transcription-engines/) (Apple Speech, WhisperKit, Parakeet) run entirely on your Mac. Audio is never uploaded, and transcription works offline once a model is downloaded.

## What does touch the network

Nothing you capture leaves your Mac unless you explicitly set that up. Remarc's network activity is limited to:

- Update checks, described under Updates below.
- Transcription model downloads: choosing the WhisperKit or Parakeet engine downloads the model in-app. Apple Speech needs no download.
- [Webhooks](/agents/webhooks/) you configure: each one sends the comment events you subscribed to, to the URL you entered. Remarc sends nothing unless you add one.
- Agent plugin installs: installing the Claude Code, Codex, or OMP integration runs that harness's own CLI, which downloads the plugin from the public [Remarc agent integrations repository](https://github.com/metedata/remarc-agent-plugins).

The [Chrome extension](/chrome-extension/) talks to the app over a local WebSocket on `127.0.0.1:9274`. That connection never leaves your machine.

## Retention

The retention pickers in [Settings](/reference/settings/) prune data automatically: comment history, stored images, and dictation transcriptions each have their own setting and schedule. Deleting a comment moves it to History first, where it can be restored until retention removes it.

## Debug logging

Release builds write no debug log. If you are troubleshooting a problem with us, you can turn logging on from Terminal:

```sh
defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES
```

Then relaunch Remarc. While the flag is set, the app writes `~/Library/Logs/Remarc/remarc_debug.log`, readable only by your account. Each launch starts a fresh file and keeps the previous launch's file next to it as `remarc_debug.log.old`, so the log stays small and a problem that spans a relaunch is still captured. The log traces app behavior, so it can include fragments of selected text, window titles, and dictation transcripts. That is what makes it useful for debugging, and why it stays off unless you enable it.

Turn logging back off with:

```sh
defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool NO
```

Remarc deletes both log files the next time it launches.

## Updates

Remarc updates itself through Sparkle, with automatic checks enabled by default and nothing to configure. Updates are signed and notarized. To check manually, use the "Check for Updates..." button in Settings > About.

## Open source

The [Remarc app](https://github.com/metedata/Remarc) and its [agent integrations](https://github.com/metedata/remarc-agent-plugins) are open source, so you can verify all of the above yourself.
