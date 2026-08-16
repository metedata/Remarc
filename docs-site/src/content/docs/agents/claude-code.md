---
title: Claude Code
description: Connect Claude Code to Remarc with the remarc plugin, and optionally let comments wake live sessions with remarc-hooks.
---

Claude Code connects to Remarc through two plugins from the public [Remarc agent integrations repository](https://github.com/metedata/remarc-agent-plugins): `remarc` (required, the MCP server and skill) and `remarc-hooks` (optional, links conversations to Remarc sessions).

## Install the remarc plugin

Three ways, all equivalent:

- **During onboarding**: click Install on the Claude Code plugin row. The row is optional; you can finish setup without it.
- **From Settings**: open Settings > MCP Integrations > Claude Code and click Install. The row shows the exact CLI commands it runs, with a copy button.
- **Manually**: run the same commands yourself:

```sh
claude plugin marketplace add metedata/remarc-agent-plugins
claude plugin install remarc@remarc
```

The first install clones the marketplace and can take a minute. If Remarc reports the plugin installed but disabled, run `/plugin` inside Claude Code to enable it.

If you upgraded from an older Remarc that configured Claude Code without plugins, the app removes the legacy skill file, hooks, and MCP registration on launch, with nothing for you to do.

## Keep the plugin updated

Claude Code doesn't update `remarc` automatically by default, because it comes from a self-hosted marketplace rather than an official one. Update it on demand, or turn on automatic updates once.

Update on demand:

```sh
claude plugin update remarc@remarc
```

If that reports the plugin is already current but you expected a newer version, refresh the marketplace first, then update again:

```sh
claude plugin marketplace update remarc
```

To update automatically, turn it on once and Claude Code refreshes the plugin in the background shortly after each session starts:

1. Run `/plugin` inside Claude Code.
2. Open the **Marketplaces** tab.
3. Select **remarc**.
4. Choose **Enable auto-update**.

The MCP server and the skill ship in the same plugin, so a single update refreshes both. After an update lands, run `/reload-plugins` to pick it up in the current session, or it loads the next time you start Claude Code.

## Install the remarc-hooks plugin (optional)

`remarc-hooks` is experimental. It ties Claude Code conversations to Remarc sessions and injects open comments at session start, so a fresh conversation begins already knowing what feedback is waiting.

Its Install button in Settings appears once `remarc` is installed, or install it manually:

```sh
claude plugin install remarc-hooks@remarc
```

With hooks installed, two Claude Code settings appear under Settings > MCP Integrations:

| Setting | Default | What it does |
| --- | --- | --- |
| Auto-create session for new conversations | On | Each new Claude Code conversation gets its own Remarc session, so comments you file land with the right agent. |
| When a conversation is cleared | Keep session | Choose Delete session, Keep session, or Move unresolved to Inbox. |

The harness-neutral **Instant delivery** section has the separate **Allow comments to wake paired agent sessions** toggle, off by default. With `remarc-hooks` installed, Send Instantly appears for a session paired with a running Claude Code agent. Inbox comments and unpaired sessions continue to arrive at the next agent read.

Quitting an agent only unlinks its session; the session and its comments stay in Remarc. The "When a conversation is cleared" setting applies when you clear the conversation.

## Hand off comments

Ask Claude Code to review your comments in plain language, or copy the sample prompt from the MCP button in the popover footer. The [MCP tools reference](/agents/mcp-tools-reference/) lists what the agent can do once connected.
