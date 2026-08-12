#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO/integrations/omp/install.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

run_default_install() {
  local agent="$ROOT/default-agent"
  OMP_AGENT_DIR="$agent" bash "$INSTALLER" >/dev/null
  OMP_AGENT_DIR="$agent" bash "$INSTALLER" >/dev/null

  [[ -L "$agent/skills/remarc" ]]
  [[ -L "$agent/skills/remarc-review" ]]
  node - "$agent/mcp.json" "$REPO/mcp/vendor/remarc-mcp.js" <<'NODE'
const fs = require("node:fs");
const [, , configPath, bundlePath] = process.argv;
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const server = config.mcpServers?.remarc;
if (!server || server.type !== "stdio" || server.command !== "node") process.exit(1);
if (server.args?.length !== 1 || server.args[0] !== bundlePath) process.exit(1);
NODE
}

run_merge_test() {
  local agent="$ROOT/merge-agent"
  mkdir -p "$agent"
  cat > "$agent/mcp.json" <<'JSON'
{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "github-mcp",
      "args": []
    }
  },
  "disabledServers": ["slack"]
}
JSON

  OMP_AGENT_DIR="$agent" bash "$INSTALLER" >/dev/null
  [[ -f "$agent/mcp.json.bak" ]]
  node - "$agent/mcp.json" <<'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!config.mcpServers?.github || !config.mcpServers?.remarc) process.exit(1);
if (config.disabledServers?.[0] !== "slack") process.exit(1);
NODE
}

run_refusal_test() {
  local agent="$ROOT/refuse-agent"
  mkdir -p "$agent"
  cat > "$agent/mcp.json" <<'JSON'
{
  "mcpServers": {
    "remarc": {
      "type": "stdio",
      "command": "different-remarc",
      "args": []
    }
  }
}
JSON

  if OMP_AGENT_DIR="$agent" bash "$INSTALLER" >/dev/null 2>&1; then
    echo "installer replaced an unmanaged remarc MCP entry" >&2
    exit 1
  fi
  [[ ! -e "$agent/skills/remarc" ]]
  [[ ! -e "$agent/skills/remarc-review" ]]
}

run_skills_only_test() {
  local agent="$ROOT/skills-agent"
  OMP_AGENT_DIR="$agent" bash "$INSTALLER" --skills-only >/dev/null
  [[ -L "$agent/skills/remarc" ]]
  [[ -L "$agent/skills/remarc-review" ]]
  [[ ! -e "$agent/mcp.json" ]]
}

run_default_install
run_merge_test
run_refusal_test
run_skills_only_test

echo "OMP installer tests passed"
