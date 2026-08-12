#!/usr/bin/env bash
# Install Remarc's MCP server and OMP review skills into an OMP agent profile.
# The repository remains the source of truth; skills are installed as symlinks.
# Safe to re-run. Existing unmanaged paths or MCP entries are never overwritten.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./integrations/omp/install.sh [--profile NAME] [--skills-only]

Options:
  --profile NAME  Install into ~/.omp/profiles/NAME/agent instead of ~/.omp/agent.
  --skills-only   Install the skills but do not edit OMP's mcp.json.
  -h, --help      Show this help.

OMP_AGENT_DIR may be set to an explicit agent directory. It cannot be combined
with --profile.
USAGE
}

PROFILE=""
INSTALL_MCP=1
while (($#)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "--profile requires a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --skills-only)
      INSTALL_MCP=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${OMP_AGENT_DIR:-}" && -n "$PROFILE" ]]; then
  echo "OMP_AGENT_DIR and --profile cannot be used together" >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${OMP_AGENT_DIR:-}" ]]; then
  AGENT_DIR="$OMP_AGENT_DIR"
elif [[ -n "$PROFILE" ]]; then
  AGENT_DIR="$HOME/.omp/profiles/$PROFILE/agent"
else
  AGENT_DIR="$HOME/.omp/agent"
fi

GENERIC_SKILL="$REPO/mcp/skill"
REVIEW_SKILL="$REPO/integrations/omp/skills/remarc-review"
MCP_BUNDLE="$REPO/mcp/vendor/remarc-mcp.js"
MCP_CONFIG="$AGENT_DIR/mcp.json"

for required in "$GENERIC_SKILL/SKILL.md" "$REVIEW_SKILL/SKILL.md"; do
  [[ -f "$required" ]] || { echo "missing required file: $required" >&2; exit 1; }
done

check_linkable() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    [[ "$current" == "$src" ]] && return 0
    echo "refusing to replace unmanaged symlink: $dst -> $current" >&2
    return 1
  fi
  if [[ -e "$dst" ]]; then
    echo "refusing to replace unmanaged path: $dst" >&2
    return 1
  fi
}

link_managed() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    echo "linked  $dst -> $src"
    return 0
  fi
  ln -s "$src" "$dst"
  echo "linked  $dst -> $src"
}

REMARC_SKILL_DEST="$AGENT_DIR/skills/remarc"
REVIEW_SKILL_DEST="$AGENT_DIR/skills/remarc-review"
check_linkable "$GENERIC_SKILL" "$REMARC_SKILL_DEST"
check_linkable "$REVIEW_SKILL" "$REVIEW_SKILL_DEST"

if ((INSTALL_MCP)); then
  command -v node >/dev/null 2>&1 || {
    echo "node is required to run the bundled Remarc MCP server" >&2
    exit 1
  }
  [[ -f "$MCP_BUNDLE" ]] || { echo "missing MCP bundle: $MCP_BUNDLE" >&2; exit 1; }

  mkdir -p "$AGENT_DIR"
  node - "$MCP_CONFIG" "$MCP_BUNDLE" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [, , configPath, bundlePath] = process.argv;
const schema = "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json";
const desired = {
  type: "stdio",
  command: "node",
  args: [bundlePath],
};

let config = {};
let original = null;
if (fs.existsSync(configPath)) {
  original = fs.readFileSync(configPath, "utf8");
  try {
    config = JSON.parse(original);
  } catch (error) {
    console.error(`refusing to edit invalid JSON: ${configPath}`);
    console.error(String(error));
    process.exit(1);
  }
}

if (!config || Array.isArray(config) || typeof config !== "object") {
  console.error(`refusing to edit non-object MCP config: ${configPath}`);
  process.exit(1);
}

if (config.mcpServers == null) config.mcpServers = {};
if (Array.isArray(config.mcpServers) || typeof config.mcpServers !== "object") {
  console.error(`refusing to edit invalid mcpServers object: ${configPath}`);
  process.exit(1);
}

const current = config.mcpServers.remarc;
const currentMatches =
  current != null &&
  !Array.isArray(current) &&
  typeof current === "object" &&
  (current.type == null || current.type === "stdio") &&
  current.command === "node" &&
  Array.isArray(current.args) &&
  current.args.length === 1 &&
  current.args[0] === bundlePath;

if (current != null && !currentMatches) {
  console.error("refusing to replace an existing unmanaged MCP server named 'remarc'");
  console.error(`existing: ${JSON.stringify(current)}`);
  console.error(`wanted:   ${JSON.stringify(desired)}`);
  process.exit(1);
}

if (config.$schema == null) config.$schema = schema;
if (current == null) config.mcpServers.remarc = desired;

const rendered = `${JSON.stringify(config, null, 2)}\n`;
if (rendered === original) {
  console.log(`kept    ${configPath} (already configured)`);
  process.exit(0);
}

fs.mkdirSync(path.dirname(configPath), { recursive: true });
if (original != null) {
  const backupPath = `${configPath}.bak`;
  if (!fs.existsSync(backupPath)) {
    fs.writeFileSync(backupPath, original, { mode: 0o600 });
    console.log(`backup  ${backupPath}`);
  }
}

const tempPath = `${configPath}.${process.pid}.tmp`;
fs.writeFileSync(tempPath, rendered, { mode: 0o600 });
fs.renameSync(tempPath, configPath);
fs.chmodSync(configPath, 0o600);
console.log(`updated ${configPath}`);
NODE
fi

link_managed "$GENERIC_SKILL" "$REMARC_SKILL_DEST"
link_managed "$REVIEW_SKILL" "$REVIEW_SKILL_DEST"

cat <<REPORT

Installed Remarc for OMP at:
  $AGENT_DIR

In OMP, run:
  /mcp reload
  /mcp test remarc

Then ask:
  Process the active Remarc review session.
REPORT

if ((!INSTALL_MCP)); then
  echo
  echo "MCP config was not changed (--skills-only). OMP must discover a Remarc"
  echo "server from another config before the skills can call Remarc tools."
fi
