# Remarc for OMP

This optional adapter makes OMP the execution surface for Remarc review sessions.
It installs the existing generic Remarc skill, an OMP-specific review workflow,
and an OMP-native MCP entry for the bundled Remarc server.

It deliberately does not turn Remarc into a task tracker or memory store:

```text
Remarc capture
  -> Reverie context
  -> Beads ownership
  -> OMP / Shepherd implementation
  -> OMP Verifier evidence
  -> Remarc resolution
```

## Requirements

- Remarc and OMP run as the same macOS user.
- Remarc has been launched at least once so its local data directory exists.
- Node.js is on `PATH` when installing the MCP entry.
- The Chrome extension is optional, but required for DOM/component context.
- Reverie, Beads, Shepherd, and OMP Verifier are optional capabilities. The
  review skill uses them when available and keeps their responsibilities separate.

Remote or container workers must be able to read Remarc screenshot paths before
they can inspect screenshot comments. The default files live under:

```text
~/Library/Application Support/Remarc/
```

## Install

From a checkout of this repository:

```bash
./integrations/omp/install.sh
```

For a named OMP profile:

```bash
./integrations/omp/install.sh --profile work
```

To install only the skills because OMP already discovers the Remarc MCP server
from Claude, Codex, or another configuration:

```bash
./integrations/omp/install.sh --skills-only
```

`OMP_AGENT_DIR` may point at an explicit OMP agent directory. The installer:

- symlinks `mcp/skill/` to `skills/remarc`;
- symlinks `integrations/omp/skills/remarc-review/` to
  `skills/remarc-review`;
- symlinks `integrations/omp/remarc-wake/` to `extensions/remarc-wake`;
- safely merges a `remarc` stdio server into OMP's `mcp.json`;
- refuses to replace unmanaged files, symlinks, or an existing different MCP
  server named `remarc`;
- creates one `mcp.json.bak` before the first managed edit of an existing file.

## Wake delivery

The `remarc-wake` OMP extension mirrors the Claude Code hook's wake path for
OMP sessions. Run `/remarc-pair` once in the OMP session you want woken to
bind it to the app's active Remarc session (pairing is explicit; nothing
pairs silently, and a pairing owned by another live session is refused).
After that, the app's Send-Instantly / wake CTA delivers flagged comments
into this session as a user message that starts a turn. If OMP is busy, the
extension waits for the current run to settle instead of queuing a stale
follow-up.

Protocol conformance follows
`docs/superpowers/specs/2026-08-06-wake-on-comment-design.md` plus the
vendored marker tooling in `mcp/vendor/remarc-mcp.js`:

- markers live in `Remarc/claude/markers/omp-<session>.json` with a
  directory lock (`<marker>.lock/`) and abandoned-owner recovery
- OMP markers carry a process ID and random owner token. A live leased owner
  cannot be replaced, even when its activity timestamp is old; ownerless
  legacy markers use timestamp liveness and are never adopted while live
- dedup is `wakedAt[commentId] = wakeRequestedAt` generation, recorded
  AFTER emit (duplicates benign, loss not); re-wake works when the comment
  is woken again (newer generation)
- OMP wake delivery is scoped to the paired session, matching the app's
  per-pairing wake CTA (the Claude-side global arbitration does not apply)
- payloads wrap user comment text and session names in per-render
  randomized sentinels and cap at 10 comments / 6,000 characters total

`/remarc-unpair` detaches. On exit the session flips its marker to
`wakeCapable: false` immediately so the app stops offering wake to a dead
target; resuming the same OMP session re-arms the pairing automatically.

Run the protocol tests directly with:

```bash
node --test integrations/omp/remarc-wake/index.test.ts
```

## Verify

Inside OMP:

```text
/mcp reload
/mcp list
/mcp test remarc
```

Then use natural language:

```text
Process the active Remarc review session.
Review the Remarc session named homepage visual pass.
Tell me what remains in the current Remarc session without changing statuses.
```

The generic `remarc` skill handles MCP semantics. The `remarc-review` skill adds
the OMP-specific boundaries: one session per review pass, one project-memory
retrieval, one durable Beads task by default, Shepherd execution, and verification
before resolution.

## OMP MCP config

The installer writes the OMP-native shape documented by Oh My Pi:

```json
{
  "$schema": "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json",
  "mcpServers": {
    "remarc": {
      "type": "stdio",
      "command": "node",
      "args": ["/absolute/path/to/Remarc/mcp/vendor/remarc-mcp.js"]
    }
  }
}
```

Default user config is `~/.omp/agent/mcp.json`. Named profiles use
`~/.omp/profiles/<name>/agent/mcp.json`.
