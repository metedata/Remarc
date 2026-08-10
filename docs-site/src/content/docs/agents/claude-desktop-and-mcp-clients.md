---
title: Claude Desktop & MCP clients
description: Connect Remarc to Claude Desktop or any JSON-config MCP client with the copyable snippets in Settings > MCP Integrations.
---

Any app that speaks MCP (Model Context Protocol) and takes JSON config can read and resolve your Remarc comments. Settings > MCP Integrations provides a ready-made snippet for Claude Desktop and a generic one for everything else. Both paths require Node.js; if it is missing, the tab shows a warning and a link to nodejs.org.

## Connect Claude Desktop

1. Open Settings > MCP Integrations and find the Claude Desktop section.
2. Copy the Claude Desktop config snippet. Remarc generates it with the correct paths for your machine, so copy it from the app rather than writing it by hand.
3. In Claude Desktop, open Claude > Settings > Developer > Edit Config and paste the snippet into the config file.
4. Restart Claude Desktop.

:::tip
After connecting, go to Customize > Connectors > Remarc in Claude Desktop and set permissions to "Always allow". Otherwise every tool call asks for approval.
:::

## Connect other MCP clients

The Other MCP clients section of the same tab covers OpenCode, Continue, Windsurf, and any other client that takes JSON config. It provides two copyable blocks:

- **MCP server config (JSON)**: a generic server entry with resolved paths. Paste it into your client's MCP server settings.
- **Skill content (SKILL.md)**: the full Remarc skill. Add it wherever your client keeps skills or custom instructions.

The JSON snippet alone is enough to connect. The skill teaches the agent the comment triage workflow and makes it noticeably better at working through comments in order and writing useful resolution summaries.

## Verify the connection

Ask the client to call `remarc_list_sessions`. If it returns your sessions, you are connected. The [MCP tools reference](/agents/mcp-tools-reference/) lists the full tool set, and the MCP status dot in the popover footer shows connection health at a glance (see the [agent overview](/agents/overview/)).
