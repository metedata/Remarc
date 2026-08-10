---
title: Cursor
description: Enable Remarc's app-managed Cursor integration; the app writes the MCP config and skill for you and uninstalls them on toggle-off.
---

The Remarc app configures Cursor directly; there is no plugin to install. The result is the same MCP (Model Context Protocol) tools and skill as every other agent; the [MCP tools reference](/agents/mcp-tools-reference/) lists them.

## Enable the integration

Open Settings > MCP Integrations > Cursor and turn on **Enable integration**. Remarc writes the configuration itself:

- `~/.cursor/mcp.json` registers the Remarc MCP server
- `~/.cursor/skills/remarc/SKILL.md` teaches Cursor the comment workflow

Two status rows, Skill and MCP server, show whether each piece is installed; check them to verify the integration. Turning the toggle off uninstalls both.

The integration requires Node.js. If the MCP server row shows "Node.js not found", install Node.js from nodejs.org and relaunch Remarc.

## Comment delivery

Comments filed to a Cursor session arrive when the agent next reads them. Sessions created by agents carry an origin badge in the [session picker](/basics/sessions/).
