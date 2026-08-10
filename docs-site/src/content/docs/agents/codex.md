---
title: Codex
description: Install the Remarc plugin for Codex from the marketplace, verify it works, and clean up config left by older Remarc builds.
---

Codex reads Remarc comments through a plugin installed from Remarc's marketplace. The plugin gives Codex the same MCP (Model Context Protocol) tools and skill as every other agent; the [MCP tools reference](/agents/mcp-tools-reference/) lists them.

## Install the plugin

Open Settings > MCP Integrations > Codex and click **Install**. The button reads **Repair** when the plugin is already installed but needs fixing. The row shows the exact CLI commands it runs, with a copy button. To run them yourself:

```sh
codex plugin marketplace add metedata/remarc-agent-plugins
codex plugin marketplace upgrade remarc
codex plugin add remarc@remarc
```

If the Codex CLI is not installed, the Install button says so; install Codex first or run the commands in a terminal.

To verify the install, ask Codex to call `remarc_list_sessions`. If your sessions come back, the plugin is working.

## Remove the plugin

The Codex integration is install-only: Remarc never removes anything from your Codex configuration. To get rid of the plugin, remove it in Codex yourself.

:::caution
If you used Remarc with Codex before the plugin existed, older builds wrote an `[mcp_servers.remarc]` table into `~/.codex/config.toml`. Remove that table by hand; the plugin replaces it.
:::

## Comment delivery

Comments filed to a Codex session arrive when the agent next reads them; Codex sessions cannot be woken instantly the way [Claude Code](/agents/claude-code/) sessions can. Sessions created by Codex carry a Codex origin badge in the [session picker](/basics/sessions/).
