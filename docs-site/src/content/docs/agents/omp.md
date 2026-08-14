---
title: OMP
description: Install Remarc's public OMP plugins, verify the MCP connection, and pair a session for instant comment delivery.
---

OMP connects through Remarc's public, MIT-licensed [agent integrations repository](https://github.com/metedata/remarc-agent-plugins). The `remarc` plugin supplies the workflow skill and MCP tools. The optional `remarc-wake` plugin pairs the current OMP conversation with one Remarc session for instant delivery.

## Requirements

- Remarc 1.1.0 or later installed and launched at least once for native OMP
  badges and instant delivery (core MCP access also works with 1.0.1)
- OMP 17.3.4 or a compatible later release
- Node.js available to the environment that launches OMP

## Install the core plugin

Run:

```sh
omp plugin marketplace add metedata/remarc-agent-plugins
omp plugin install --scope user remarc@remarc
```

For only the current project, use `--scope project` from that project directory. In an already running OMP session, reload and verify discovery:

```text
/reload-plugins
/mcp list
/mcp test remarc:remarc
/skill:remarc
```

OMP displays the MCP server as `remarc:remarc`. Ask OMP to list Remarc sessions or comments; you do not need to use its generated internal tool identifiers yourself.

## Add instant delivery

Install the optional wake extension from the same public marketplace:

```sh
omp plugin install --scope user remarc-wake@remarc
```

Restart OMP after installing or updating an extension. In the OMP conversation that should receive comments, run:

```text
/remarc-pair
```

Before pairing, make the intended session active in Remarc. You can create it in the app or ask OMP to create a correctly labelled Remarc session through MCP. `/remarc-pair` binds the current OMP conversation to that active Remarc session; it does not guess or silently create one. Then enable **Allow comments to wake paired agent sessions** in Remarc under Settings > MCP Integrations > Instant delivery. Send Instantly appears only while the selected session has a live, token-owned OMP pairing.

Run `/remarc-unpair` to remove the current conversation's pairing. A normal OMP shutdown removes its live lease; after a forced exit, the short heartbeat timeout makes the stale pairing unreachable without deleting any Remarc data.

## Update or remove

```sh
omp plugin marketplace update remarc
omp plugin upgrade --scope user remarc@remarc
omp plugin upgrade --scope user remarc-wake@remarc
omp plugin uninstall --scope user remarc-wake@remarc
omp plugin uninstall --scope user remarc@remarc
```

Use `--scope project` for project-scoped installs. Remarc deliberately does not write OMP configuration, scan OMP profile directories, or infer install status from files; OMP's own plugin manager remains the source of truth.

## Data and security

Both plugins run locally with your user permissions. They read Remarc's local data file and communicate with OMP in-process or over local stdio; Remarc operates no integration server and adds no telemetry. Comment text, captured page content, and screenshots may still be sent to the model provider configured in OMP.

For package internals, compatibility evidence, development instructions, and release history, see the [integration repository documentation](https://github.com/metedata/remarc-agent-plugins#readme).
