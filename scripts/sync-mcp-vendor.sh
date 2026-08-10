#!/usr/bin/env bash
# Refresh the vendored MCP server from the plugin repo, which owns it.
#
# The server used to be written twice - here and in the plugin repo - and kept
# in sync by hand. It wasn't: the app shipped a build with none of the document
# transaction, unknown-field passthrough, or status compare-and-set, for months.
# Every fix had to be made in two places and one of them was always forgotten.
#
# There is one implementation now. This copies its built artifact and records
# exactly which commit produced it, so a stale vendor is a visible fact rather
# than an invisible one.
#
# Usage: scripts/sync-mcp-vendor.sh [path-to-plugin-repo]
set -euo pipefail

PLUGIN_REPO="${1:-${REMARC_PLUGIN_REPO:-$HOME/Developer/remarc-agent-plugins}}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/mcp/vendor"
SRC="$PLUGIN_REPO/plugins/remarc/mcp"

[ -d "$SRC" ] || { echo "error: no plugin repo at $PLUGIN_REPO" >&2; exit 1; }

# Build from source rather than trusting a committed dist that may itself be
# stale - the exact failure this script exists to prevent.
( cd "$SRC" && npm ci --prefer-offline --no-audit --fund=false >/dev/null && npm run build >/dev/null )

COMMIT="$(git -C "$PLUGIN_REPO" rev-parse HEAD)"
DIRTY="$(git -C "$PLUGIN_REPO" status --porcelain | head -1)"
if [ -n "$DIRTY" ]; then
  echo "error: plugin repo has uncommitted changes; vendor only from a committed state" >&2
  exit 1
fi

VERSION="$(python3 -c "import json;print(json.load(open('$PLUGIN_REPO/plugins/remarc/.claude-plugin/plugin.json'))['version'])")"

mkdir -p "$DEST"
cp "$SRC/dist/index.js" "$DEST/remarc-mcp.js"
SHA="$(shasum -a 256 "$DEST/remarc-mcp.js" | awk '{print $1}')"

cat > "$DEST/PROVENANCE.json" <<EOF
{
  "source": "https://github.com/metedata/remarc-agent-plugins",
  "path": "plugins/remarc/mcp/dist/index.js",
  "commit": "$COMMIT",
  "pluginVersion": "$VERSION",
  "sha256": "$SHA"
}
EOF

echo "vendored $VERSION from ${COMMIT:0:12} (sha256 ${SHA:0:16})"
