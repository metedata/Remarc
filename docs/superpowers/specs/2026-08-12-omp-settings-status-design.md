# OMP Settings Status Design

## Problem

Remarc installs an OMP MCP server, skills, and wake extension, but Preferences has no OMP section. OMP is grouped under “Other MCP clients,” which offers static snippets and cannot report installation state. The Send Instantly preference is also nested under Claude Code’s `remarc-hooks` section, so OMP users cannot enable it without installing an unrelated Claude plugin.

## Design

Add an **OMP** section to MCP Integrations between Claude Code and Codex. It has two status rows:

- **remarc** reports whether the Remarc MCP server and generic skill are installed in an OMP agent profile.
- **remarc-wake** reports whether the OMP wake extension and review skill are installed in that profile, and reports **Active** when a live OMP pairing marker exists.

Detection checks the default agent directory (`~/.omp/agent`) and named profiles (`~/.omp/profiles/<name>/agent`). A profile counts as configured only when its required files agree. Partial or malformed installations report that setup is needed. The row identifies configured profiles so users know which OMP invocation can load the integration.

When setup is missing or incomplete, the section links to the repository’s OMP setup instructions. Remarc does not duplicate the shell installer in Swift or show a repo-relative command that cannot work from a distributed app.

Add a separate **Instant delivery** section after OMP. Move the shared wake preference there and rename it to **Allow comments to wake paired agent sessions**. Its help text describes both Claude Code and OMP. Claude-only auto-session and conversation-clear controls remain in the Claude Code section.

## State and Data Flow

A small detector reads OMP configuration from the user’s home directory when the MCP Integrations tab appears. The SwiftUI view stores the detector result as view state and renders pending, installed, or needs-setup status through the existing integration-row vocabulary. `WakeReachability` separately reports whether an OMP pairing is live, allowing `remarc-wake` to distinguish **Active** from merely **Installed**.

Configuration detection does not run OMP, modify files, infer the active shell profile, or treat a live pairing marker as installation proof. The marker only refines runtime status after the disk installation is valid. There is no persistent “connected” state for the stdio MCP server because OMP starts it on demand.

## Failure Handling

- Missing OMP directories: report Not installed.
- Invalid `mcp.json`: report Needs setup without replacing it.
- MCP server without the skill, or extension without the review skill: report Needs setup.
- Multiple profiles: list each fully configured profile; do not combine components from different profiles.
- Unrelated OMP configuration: preserve and ignore it.

## Verification

Tests cover default-profile installation, named profiles, multiple profiles, missing components, malformed JSON, absent configuration, and live OMP marker filtering. Then run the focused tests, the full Swift suite, an unsigned app build, relaunch the built app, and inspect MCP Integrations to confirm the OMP and Instant delivery sections render correctly.
