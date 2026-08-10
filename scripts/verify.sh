#!/bin/bash
# Remarc Verification Toolkit
# Usage: scripts/verify.sh [build|launch|screenshot|crop|smoke-test|full]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
WORKSPACE="$APP_DIR/Remarc.xcworkspace"
SCHEME="Remarc"
APP_NAME="Remarc"
SCREENSHOT_DIR="$REPO_ROOT/tests/screenshots"
AX_INSPECT="$REPO_ROOT/tools/ax-inspect/.build/debug/ax-inspect"
DERIVED_DATA="$APP_DIR/DerivedData"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
DEBUG_LOG="/tmp/remarc_debug.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Ensure the workspace exists (it's gitignored, so worktrees may not have it)
ensure_workspace() {
    if [ ! -d "$WORKSPACE" ]; then
        log_info "Creating workspace (gitignored, not in worktree)..."
        mkdir -p "$WORKSPACE"
        cat > "$WORKSPACE/contents.xcworkspacedata" << 'WSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:RemarcPackage">
   </FileRef>
   <FileRef
      location = "container:Remarc.xcodeproj">
   </FileRef>
</Workspace>
WSEOF
        log_ok "Workspace created"
    fi
}

ensure_ax_inspect() {
    if [ ! -f "$AX_INSPECT" ]; then
        log_info "Building ax-inspect..."
        (cd "$REPO_ROOT/tools/ax-inspect" && swift build -q 2>&1)
        log_ok "ax-inspect built"
    fi
}

cmd_build() {
    ensure_workspace
    log_info "Building $SCHEME (Debug)..."
    cd "$APP_DIR"
    local build_log
    build_log="$(mktemp "${TMPDIR:-/tmp}/remarc-build.XXXXXX")"
    if xcodebuild build \
        -workspace Remarc.xcworkspace \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$(pwd)/DerivedData" \
        -quiet >"$build_log" 2>&1; then
        cat "$build_log"
        rm -f "$build_log"
    else
        local build_status=$?
        cat "$build_log" >&2
        rm -f "$build_log"
        cd "$REPO_ROOT"
        log_fail "Build failed (xcodebuild exit $build_status)"
        exit "$build_status"
    fi
    cd "$REPO_ROOT"
    log_ok "Build succeeded"
    cmd_launch
}

find_app_path() {
    local app="$DERIVED_DATA/Build/Products/Debug/${APP_NAME}.app"
    if [ -d "$app" ]; then
        echo "$app"
    fi
}

cmd_launch() {
    local app_path
    app_path="$(find_app_path)"
    if [ -z "$app_path" ]; then
        log_fail "Could not find built app. Run 'verify.sh build' first."
        exit 1
    fi

    # Kill existing instance
    killall "$APP_NAME" 2>/dev/null || true
    sleep 0.5

    # Clear debug log
    > "$DEBUG_LOG" 2>/dev/null || true

    log_info "Launching $app_path..."
    open "$app_path"

    # Wait for app to be ready
    for i in $(seq 1 10); do
        if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
            sleep 1  # Extra time for UI initialization
            log_ok "App launched (pid: $(pgrep -x "$APP_NAME"))"
            return
        fi
        sleep 0.5
    done
    log_fail "App did not start within 5 seconds"
    exit 1
}

cmd_kill() {
    killall "$APP_NAME" 2>/dev/null && log_ok "Killed $APP_NAME" || log_info "$APP_NAME was not running"
}

cmd_screenshot() {
    local label="${1:-screen}"
    local filename="${TIMESTAMP}_${label}.png"
    mkdir -p "$SCREENSHOT_DIR"

    # Check if we should capture a specific window region
    if [ "${2:-}" = "--region" ] && [ -n "${3:-}" ]; then
        local frame="$3"  # format: x,y,w,h
        IFS=',' read -r x y w h <<< "$frame"
        screencapture -x -R"${x},${y},${w},${h}" "$SCREENSHOT_DIR/$filename"
    else
        screencapture -x "$SCREENSHOT_DIR/$filename"
    fi

    log_ok "Screenshot: $SCREENSHOT_DIR/$filename"
    echo "$SCREENSHOT_DIR/$filename"
}

cmd_crop() {
    local input_file=""
    local identifier=""
    local region=""
    local padding=20

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --identifier) identifier="$2"; shift 2 ;;
            --region)     region="$2"; shift 2 ;;
            --padding)    padding="$2"; shift 2 ;;
            -*)           log_fail "Unknown option: $1"; exit 1 ;;
            *)
                if [ -z "$input_file" ]; then
                    input_file="$1"; shift
                else
                    log_fail "Unexpected argument: $1"; exit 1
                fi
                ;;
        esac
    done

    # Validate: input file required
    if [ -z "$input_file" ]; then
        log_fail "Usage: verify.sh crop <screenshot.png> --identifier <id> [--padding <px>]"
        log_fail "       verify.sh crop <screenshot.png> --region x,y,w,h [--padding <px>]"
        exit 1
    fi

    # Resolve input file: try as-is, then $SCREENSHOT_DIR/ prefix
    if [ ! -f "$input_file" ]; then
        if [ -f "$SCREENSHOT_DIR/$input_file" ]; then
            input_file="$SCREENSHOT_DIR/$input_file"
        else
            log_fail "File not found: $input_file"
            log_info "Available screenshots in $SCREENSHOT_DIR:"
            ls -1 "$SCREENSHOT_DIR"/*.png 2>/dev/null || echo "  (none)"
            exit 1
        fi
    fi

    # Validate: exactly one of --identifier or --region
    if [ -n "$identifier" ] && [ -n "$region" ]; then
        log_fail "Specify either --identifier or --region, not both"
        exit 1
    fi
    if [ -z "$identifier" ] && [ -z "$region" ]; then
        log_fail "Specify --identifier <id> or --region x,y,w,h"
        exit 1
    fi

    # Get image dimensions and DPI via sips
    local img_w img_h dpi scale
    img_w=$(sips -g pixelWidth "$input_file" | tail -1 | awk '{print $2}')
    img_h=$(sips -g pixelHeight "$input_file" | tail -1 | awk '{print $2}')
    dpi=$(sips -g dpiWidth "$input_file" | tail -1 | awk '{print $2}' | cut -d. -f1)

    if [ -z "$dpi" ] || [ "$dpi" -le 0 ] 2>/dev/null; then
        log_info "Could not determine DPI, defaulting to 144 (2x Retina)"
        dpi=144
    fi
    scale=$(( (dpi + 36) / 72 ))  # round(dpi/72)
    if [ "$scale" -lt 1 ]; then scale=1; fi
    log_info "Image: ${img_w}x${img_h}px, ${dpi}dpi, scale=${scale}x"

    local crop_x crop_y crop_w crop_h output_suffix

    if [ -n "$identifier" ]; then
        # Check app is running
        if ! pgrep -x "$APP_NAME" > /dev/null 2>&1; then
            log_fail "App is not running. Cannot look up AX identifier."
            log_info "Either run 'verify.sh launch' first, or use --region for manual coordinates."
            exit 1
        fi

        ensure_ax_inspect

        # Get element info via ax-inspect find
        local ax_json
        ax_json=$("$AX_INSPECT" find --identifier "$identifier" --app "$APP_NAME" 2>&1) || {
            log_fail "Element not found: $identifier"
            log_info "Available identifiers:"
            "$AX_INSPECT" tree --app "$APP_NAME" --depth 10 2>&1 | python3 -c "
import json, sys
def collect(node):
    ids = []
    if 'identifier' in node and node['identifier']:
        ids.append(node['identifier'])
    for child in node.get('children', []):
        ids.extend(collect(child))
    return ids
try:
    tree = json.load(sys.stdin)
    for i in sorted(set(collect(tree))):
        print(f'  {i}')
except: pass
" || true
            exit 1
        }

        # Parse JSON fields in one python3 call
        local ax_x ax_y ax_w ax_h ax_role ax_title
        read -r ax_x ax_y ax_w ax_h ax_role ax_title <<< "$(python3 -c "
import json, sys
d = json.loads('''$ax_json''')
f = d['frame']
print(f['x'], f['y'], f['width'], f['height'],
      d.get('role') or 'unknown', d.get('title') or 'untitled')
")"

        log_info "Element: $identifier (role=$ax_role, title=$ax_title)"
        log_info "AX frame: x=$ax_x y=$ax_y w=$ax_w h=$ax_h (points)"

        # Sanity check: zero-size frame
        if [ "$ax_w" = "0" ] || [ "$ax_h" = "0" ] || [ "$ax_w" = "0.0" ] || [ "$ax_h" = "0.0" ]; then
            log_fail "Element has zero-size frame — it may be hidden or collapsed"
            exit 1
        fi

        # Convert points to pixels, apply padding (in points, scaled to pixels)
        local pad_px=$(( padding * scale ))
        crop_x=$(python3 -c "print(max(0, int($ax_x * $scale - $pad_px)))")
        crop_y=$(python3 -c "print(max(0, int($ax_y * $scale - $pad_px)))")
        local raw_w=$(python3 -c "print(int($ax_w * $scale + 2 * $pad_px))")
        local raw_h=$(python3 -c "print(int($ax_h * $scale + 2 * $pad_px))")

        # Clamp to image bounds
        crop_w=$(python3 -c "print(min($raw_w, $img_w - $crop_x))")
        crop_h=$(python3 -c "print(min($raw_h, $img_h - $crop_y))")

        output_suffix="${identifier//\./_}"

    else
        # --region: parse x,y,w,h (already in pixels)
        IFS=',' read -r rx ry rw rh <<< "$region"
        if [ -z "$rx" ] || [ -z "$ry" ] || [ -z "$rw" ] || [ -z "$rh" ]; then
            log_fail "Invalid region format. Expected: x,y,w,h (e.g., 100,200,300,400)"
            exit 1
        fi

        # Apply padding (raw pixels, no scaling)
        crop_x=$(python3 -c "print(max(0, int($rx - $padding)))")
        crop_y=$(python3 -c "print(max(0, int($ry - $padding)))")
        local raw_w=$(python3 -c "print(int($rw + 2 * $padding))")
        local raw_h=$(python3 -c "print(int($rh + 2 * $padding))")

        # Clamp to image bounds
        crop_w=$(python3 -c "print(min($raw_w, $img_w - $crop_x))")
        crop_h=$(python3 -c "print(min($raw_h, $img_h - $crop_y))")

        output_suffix="region-${rx}-${ry}-${rw}-${rh}"
    fi

    log_info "Crop region: x=$crop_x y=$crop_y w=$crop_w h=$crop_h (pixels)"

    # Generate output filename
    local base
    base="$(basename "$input_file" .png)"
    local output_file="$SCREENSHOT_DIR/${base}_${output_suffix}.png"
    mkdir -p "$SCREENSHOT_DIR"

    # Crop using sips: --cropOffset Y X then -c H W
    if ! sips "$input_file" --cropOffset "$crop_y" "$crop_x" -c "$crop_h" "$crop_w" --out "$output_file" > /dev/null 2>&1; then
        log_fail "sips crop failed. Manual retry:"
        log_fail "  sips \"$input_file\" --cropOffset $crop_y $crop_x -c $crop_h $crop_w --out \"$output_file\""
        exit 1
    fi

    # Verify output
    if [ ! -f "$output_file" ]; then
        log_fail "Output file was not created: $output_file"
        exit 1
    fi

    local out_w out_h
    out_w=$(sips -g pixelWidth "$output_file" | tail -1 | awk '{print $2}')
    out_h=$(sips -g pixelHeight "$output_file" | tail -1 | awk '{print $2}')
    log_ok "Cropped: ${out_w}x${out_h}px → $output_file"
    echo "$output_file"
}

cmd_smoke_test() {
    ensure_ax_inspect
    log_info "Running smoke test..."

    # 1. Check app is running
    if ! pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        log_fail "App is not running. Run 'verify.sh launch' first."
        exit 1
    fi
    log_ok "App is running (pid: $(pgrep -x "$APP_NAME"))"

    # 2. List windows
    log_info "Listing windows..."
    local windows
    windows=$("$AX_INSPECT" list-windows --app "$APP_NAME" 2>&1) || true
    echo "$windows"
    log_ok "Windows listed"

    # 3. Screenshot full screen
    cmd_screenshot "smoke-fullscreen"

    # 4. Check debug log for startup messages
    if [ -f "$DEBUG_LOG" ]; then
        if grep -q "AppController setup complete" "$DEBUG_LOG" 2>/dev/null; then
            log_ok "App setup completed (verified from debug log)"
        else
            log_info "Debug log exists but setup completion not confirmed"
        fi
    else
        log_info "No debug log found at $DEBUG_LOG"
    fi

    log_ok "Smoke test complete"
}

cmd_full() {
    cmd_build
    sleep 2  # Extra settle time for UI
    cmd_smoke_test
}

cmd_ax() {
    ensure_ax_inspect
    # Pass all remaining args to ax-inspect
    shift  # Remove "ax" from args
    "$AX_INSPECT" "$@"
}

# Main dispatch
case "${1:-help}" in
    build)      cmd_build ;;
    launch)     cmd_launch ;;
    kill)       cmd_kill ;;
    screenshot) shift; cmd_screenshot "$@" ;;
    crop)       shift; cmd_crop "$@" ;;
    smoke-test) cmd_smoke_test ;;
    full)       cmd_full ;;
    ax)         cmd_ax "$@" ;;
    help|*)
        echo "Remarc Verification Toolkit"
        echo ""
        echo "Usage: verify.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  build        Build the app (Debug configuration) and relaunch it"
        echo "  launch       Kill existing instance & launch fresh build"
        echo "  kill         Kill running instance"
        echo "  screenshot   Take screenshot [label] [--region x,y,w,h]"
        echo "  crop         Crop element from screenshot --identifier <id> or --region x,y,w,h"
        echo "  smoke-test   Quick check: app running, windows visible, screenshot"
        echo "  full         Build + launch + smoke test"
        echo "  ax <cmd>     Run ax-inspect command (pass-through)"
        echo ""
        echo "Examples:"
        echo "  scripts/verify.sh full"
        echo "  scripts/verify.sh screenshot corner-widget"
        echo "  scripts/verify.sh screenshot viewer --region 100,200,800,550"
        echo "  scripts/verify.sh crop screenshot.png --identifier remarc.cornerWidget"
        echo "  scripts/verify.sh crop screenshot.png --identifier remarc.viewer --padding 40"
        echo "  scripts/verify.sh crop screenshot.png --region 100,200,300,400"
        echo "  scripts/verify.sh ax list-windows"
        echo "  scripts/verify.sh ax find --identifier remarc.viewer"
        ;;
esac
