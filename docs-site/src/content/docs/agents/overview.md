---
title: Agent overview
description: Which AI coding agents work with Remarc, how each one connects over MCP, and where to find each setup guide.
---

Remarc hands your comments to AI coding agents over MCP (Model Context Protocol): leave comments as you review, then tell the agent to work through them. The agent reads each comment with its context (the quoted selection, source app, screenshot image paths, and web element details like CSS selectors and component file paths), moves it through the status lifecycle, and ends with a resolution summary you can read on the card.

## Supported agents

Remarc connects to agents through three delivery models; each page below covers one setup path.

| Agent | Delivery | Setup |
| --- | --- | --- |
| Claude Code | Plugin | [Claude Code](/agents/claude-code/) |
| Codex | Plugin | [Codex](/agents/codex/) |
| OMP | Plugin | [OMP](/agents/omp/) |
| Cursor | App-managed | [Cursor](/agents/cursor/) |
| Claude Desktop | Manual config | [Claude Desktop & MCP clients](/agents/claude-desktop-and-mcp-clients/) |
| Any MCP client | Manual config | [Claude Desktop & MCP clients](/agents/claude-desktop-and-mcp-clients/) |

Claude Code, Codex, and OMP install plugins from Remarc's public [agent integrations repository](https://github.com/metedata/remarc-agent-plugins). The app configures Cursor itself, driven by an Enable toggle. Claude Desktop and other MCP clients (OpenCode, Continue, Windsurf, and anything that takes JSON config) use copyable snippets from Settings > MCP Integrations.

Whatever the path, every connected agent gets the same seven tools; the [MCP tools reference](/agents/mcp-tools-reference/) lists them. Tools that do not speak MCP can still receive comments through [webhooks](/agents/webhooks/).

## Sessions and connection status

Comments live in [sessions](/basics/sessions/), and sessions can pair with agent conversations. Sessions created by an agent carry its origin badge (Claude Code, Codex, or OMP) so you can tell who created what.

The popover footer has an MCP button with a status dot: green when connected, orange when a dependency is missing, red when not connected. Click it for details and a copyable sample prompt.
