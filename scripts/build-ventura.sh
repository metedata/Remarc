#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REMARC_VENTURA=1
cd "$REPO_ROOT/app"

# Resolve the reduced dependency graph, retaining the upstream pinned revisions.
PIN_BACKUP_DIR="$(mktemp -d)"
PIN_BACKUP="$PIN_BACKUP_DIR/package.resolved"
LOCK_DIR="$REPO_ROOT/app/Remarc.xcworkspace/xcshareddata/swiftpm"
cp RemarcPackage/Package.resolved "$PIN_BACKUP"
if [[ -f "$LOCK_DIR/Package.resolved" ]]; then
  cp "$LOCK_DIR/Package.resolved" "$PIN_BACKUP_DIR/workspace.resolved"
fi
restore_locks() {
  cp "$PIN_BACKUP" "$REPO_ROOT/app/RemarcPackage/Package.resolved"
  if [[ -f "$PIN_BACKUP_DIR/workspace.resolved" ]]; then
    cp "$PIN_BACKUP_DIR/workspace.resolved" "$LOCK_DIR/Package.resolved"
  else
    rm -f "$LOCK_DIR/Package.resolved"
  fi
  rm -rf "$PIN_BACKUP_DIR"
}
trap restore_locks EXIT
swift package --package-path RemarcPackage resolve
python3 - "$PIN_BACKUP" RemarcPackage/Package.resolved <<'PY'
import json, sys
original, resolved = [json.load(open(path))['pins'] for path in sys.argv[1:]]
expected = {p['identity']: p['state']['revision'] for p in original if p['identity'] != 'fluidaudio'}
actual = {p['identity']: p['state']['revision'] for p in resolved}
if actual != expected:
    raise SystemExit('Ventura resolution changed pinned dependencies; review Package.resolved before building')
PY
mkdir -p "$LOCK_DIR"
cp RemarcPackage/Package.resolved "$LOCK_DIR/Package.resolved"

xcodebuild clean build \
  -workspace "$REPO_ROOT/app/Remarc.xcworkspace" \
  -scheme Remarc -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$(pwd)/DerivedData" \
  -xcconfig "$REPO_ROOT/app/Config/Ventura.xcconfig" \
  -onlyUsePackageVersionsFromResolvedFile

APP="$REPO_ROOT/app/DerivedData/Build/Products/Debug/Remarc.app"
codesign --force --sign - --timestamp=none \
  --entitlements "$REPO_ROOT/app/Config/Ventura.entitlements" "$APP"
# Relaunch after every successful app build, including on the CI build host.
pkill -x Remarc || true
sleep 0.5
open "$APP"
python3 "$REPO_ROOT/scripts/verify-ventura-app.py" "$APP"
codesign --verify --deep --strict "$APP"
