---
title: Claude Code
description: Connect Claude Code to Remarc with the remarc plugin, and optionally let comments wake live sessions with remarc-hooks.
---

Claude Code connects to Remarc through two plugins from the `metedata/remarc-agent-plugins` marketplace: `remarc` (required, the MCP server and skill) and `remarc-hooks` (optional, links conversations to Remarc sessions).

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

## Install the remarc-hooks plugin (optional)

`remarc-hooks` is experimental. It ties Claude Code conversations to Remarc sessions and injects open comments at session start, so a fresh conversation begins already knowing what feedback is waiting.

Its Install button in Settings appears once `remarc` is installed, or install it manually:

```sh
claude plugin install remarc-hooks@remarc
```

With hooks installed, three settings appear under Settings > MCP Integrations:

| Setting | Default | What it does |
| --- | --- | --- |
| Auto-create session for new conversations | On | Each new Claude Code conversation gets its own Remarc session, so comments you file land with the right agent. |
| Allow comments to wake Claude Code sessions | Off | Adds a Send Instantly button beside Save in the composer that interrupts the session's Claude Code agent with the comment right away. |
| When a conversation is cleared | Keep session | Choose Delete session, Keep session, or Move unresolved to Inbox. |

Send Instantly appears only for a session paired with a running Claude Code agent. Inbox comments and Codex sessions cannot be woken; those comments arrive at the agent's next prompt instead.

Quitting an agent only unlinks its session; the session and its comments stay in Remarc. The "When a conversation is cleared" setting applies when you clear the conversation.

## Hand off comments

Ask Claude Code to review your comments in plain language, or copy the sample prompt from the MCP button in the popover footer. The [MCP tools reference](/agents/mcp-tools-reference/) lists what the agent can do once connected.
