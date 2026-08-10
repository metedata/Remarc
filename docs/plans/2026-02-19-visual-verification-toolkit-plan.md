# Visual Verification Toolkit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a shell-based toolkit that lets Claude Code autonomously build, launch, interact with, screenshot, and verify the Remarc macOS app after making code changes.

**Architecture:** A Swift CLI (`ax-inspect`) for AX-based element inspection/interaction, a shell script (`verify.sh`) for orchestration, and accessibility identifiers added to SwiftUI views. Screenshots captured via `screencapture` and viewed via Claude's multimodal Read tool.

**Tech Stack:** Swift 6.0+, SPM, ApplicationServices/AXUIElement API, AppleScript, screencapture

---

### Task 1: Scaffold directories and gitignore

**Files:**
- Create: `tests/screenshots/.gitkeep`
- Create: `tools/ax-inspect/Package.swift`
- Create: `tools/ax-inspect/Sources/main.swift` (placeholder)
- Modify: `.gitignore` (add `tests/screenshots/` entry)

**Step 1: Create directory structure**

```bash
mkdir -p /Users/metepolat/Developer/Remarc/tests/screenshots
touch /Users/metepolat/Developer/Remarc/tests/screenshots/.gitkeep
mkdir -p /Users/metepolat/Developer/Remarc/tools/ax-inspect/Sources
mkdir -p /Users/metepolat/Developer/Remarc/scripts
```

**Step 2: Create ax-inspect Package.swift**

```swift
// tools/ax-inspect/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ax-inspect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ax-inspect",
            path: "Sources"
        )
    ]
)
```

**Step 3: Create placeholder main.swift**

```swift
// tools/ax-inspect/Sources/main.swift
import Foundation
print("ax-inspect: placeholder")
```

**Step 4: Update .gitignore**

Add these lines:
```
tests/screenshots/*.png
tests/screenshots/*.jpg
!tests/screenshots/.gitkeep
```

**Step 5: Verify the SPM package resolves**

Run: `cd /Users/metepolat/Developer/Remarc/tools/ax-inspect && swift build`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add tests/screenshots/.gitkeep tools/ax-inspect/ scripts/ .gitignore
git commit -m "feat: scaffold verification toolkit directories and ax-inspect package"
```

---

### Task 2: Build ax-inspect CLI — list-windows command

**Files:**
- Modify: `tools/ax-inspect/Sources/main.swift`
- Create: `tools/ax-inspect/Sources/AXHelpers.swift`

**Step 1: Write AXHelpers.swift with window listing**

```swift
// tools/ax-inspect/Sources/AXHelpers.swift
import ApplicationServices
import Foundation

enum AXError: Error, CustomStringConvertible {
    case appNotFound(String)
    case axError(String)

    var description: String {
        switch self {
        case .appNotFound(let name): return "App not found: \(name)"
        case .axError(let msg): return "AX error: \(msg)"
        }
    }
}

struct WindowInfo: Encodable {
    let index: Int
    let title: String
    let role: String
    let subrole: String
    let frame: FrameInfo
    let isVisible: Bool

    struct FrameInfo: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

func findApp(named name: String) -> pid_t? {
    let workspace = NSWorkspace.shared
    return workspace.runningApplications
        .first(where: { $0.localizedName == name || $0.bundleIdentifier?.contains(name.lowercased()) == true })?
        .processIdentifier
}

func listWindows(appName: String) throws -> [WindowInfo] {
    guard let pid = findApp(named: appName) else {
        throw AXError.appNotFound(appName)
    }

    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        return []
    }

    var infos: [WindowInfo] = []
    for (index, window) in windows.enumerated() {
        let title = getStringAttribute(window, kAXTitleAttribute) ?? ""
        let role = getStringAttribute(window, kAXRoleAttribute) ?? ""
        let subrole = getStringAttribute(window, kAXSubroleAttribute) ?? ""
        let frame = getFrame(window)
        let isVisible = !(getStringAttribute(window, kAXHiddenAttribute) == "1")

        infos.append(WindowInfo(
            index: index,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isVisible: isVisible
        ))
    }
    return infos
}

func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? String
}

func getFrame(_ element: AXUIElement) -> WindowInfo.FrameInfo {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

    var position = CGPoint.zero
    var size = CGSize.zero
    if let posRef = posRef {
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
    }
    if let sizeRef = sizeRef {
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    }

    return WindowInfo.FrameInfo(
        x: Double(position.x),
        y: Double(position.y),
        width: Double(size.width),
        height: Double(size.height)
    )
}
```

**Step 2: Write main.swift with argument parsing**

```swift
// tools/ax-inspect/Sources/main.swift
import Foundation

@main
struct AXInspect {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        let command = args[1]
        let appName = getFlag(args, "--app") ?? "Remarc"

        do {
            switch command {
            case "list-windows":
                let windows = try listWindows(appName: appName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(windows)
                print(String(data: data, encoding: .utf8)!)

            default:
                print("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    static func getFlag(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func printUsage() {
        print("""
        Usage: ax-inspect <command> [options]

        Commands:
          list-windows    List all windows for an app
          tree            Print AX element tree for a window
          find            Find element by accessibility identifier
          read            Read value of element by identifier
          click           Click element by identifier
          frame           Get frame of element by identifier

        Options:
          --app <name>    App name (default: Remarc)
          --identifier <id>  Accessibility identifier to find
          --window <idx>  Window index (from list-windows)
          --depth <n>     Max tree depth (default: 5)
        """)
    }
}
```

Note: Remove the `@main` attribute if using top-level code. Use top-level code approach to keep it simpler:

```swift
// tools/ax-inspect/Sources/main.swift
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let command = args[1]
let appName = getFlag(args, "--app") ?? "Remarc"

do {
    switch command {
    case "list-windows":
        let windows = try listWindows(appName: appName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(windows)
        print(String(data: data, encoding: .utf8)!)
    default:
        print("Unknown command: \(command)")
        printUsage()
        exit(1)
    }
} catch {
    print("Error: \(error)")
    exit(1)
}

func getFlag(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func printUsage() {
    print("""
    Usage: ax-inspect <command> [options]

    Commands:
      list-windows    List all windows for an app
      tree            Print AX element tree for a window
      find            Find element by accessibility identifier
      read            Read value of element by identifier
      click           Click element by identifier
      frame           Get frame of element by identifier

    Options:
      --app <name>    App name (default: Remarc)
      --identifier <id>  Accessibility identifier to find
      --window <idx>  Window index (from list-windows)
      --depth <n>     Max tree depth (default: 5)
    """)
}
```

**Step 3: Build and test**

Run: `cd /Users/metepolat/Developer/Remarc/tools/ax-inspect && swift build`
Expected: Build succeeds

Run: `.build/debug/ax-inspect list-windows --app "Remarc"`
Expected: JSON output of windows (empty array if app not running, or list of panels if running)

**Step 4: Commit**

```bash
git add tools/ax-inspect/Sources/
git commit -m "feat: ax-inspect list-windows command with AX helpers"
```

---

### Task 3: Build ax-inspect CLI — tree, find, read commands

**Files:**
- Modify: `tools/ax-inspect/Sources/AXHelpers.swift`
- Modify: `tools/ax-inspect/Sources/main.swift`

**Step 1: Add tree traversal and element finding to AXHelpers.swift**

Add these functions to AXHelpers.swift:

```swift
struct ElementInfo: Encodable {
    let role: String
    let identifier: String
    let title: String
    let value: String
    let frame: WindowInfo.FrameInfo
    let children: [ElementInfo]?
}

func getWindowElement(appName: String, windowIndex: Int) throws -> AXUIElement {
    guard let pid = findApp(named: appName) else {
        throw AXError.appNotFound(appName)
    }
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    guard let windows = windowsRef as? [AXUIElement], windowIndex < windows.count else {
        throw AXError.axError("Window index \(windowIndex) out of range")
    }
    return windows[windowIndex]
}

func buildTree(_ element: AXUIElement, depth: Int, maxDepth: Int) -> ElementInfo {
    let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
    let identifier = getStringAttribute(element, kAXIdentifierAttribute) ?? ""
    let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
    let value = getStringAttribute(element, kAXValueAttribute) ?? ""
    let frame = getFrame(element)

    var children: [ElementInfo]? = nil
    if depth < maxDepth {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let childElements = childrenRef as? [AXUIElement] {
            children = childElements.map { buildTree($0, depth: depth + 1, maxDepth: maxDepth) }
        }
    }

    return ElementInfo(role: role, identifier: identifier, title: title, value: value, frame: frame, children: children)
}

func findElement(in element: AXUIElement, identifier: String) -> AXUIElement? {
    let id = getStringAttribute(element, kAXIdentifierAttribute) ?? ""
    if id == identifier { return element }

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    if let children = childrenRef as? [AXUIElement] {
        for child in children {
            if let found = findElement(in: child, identifier: identifier) {
                return found
            }
        }
    }
    return nil
}

func findInAllWindows(appName: String, identifier: String) throws -> (AXUIElement, WindowInfo.FrameInfo)? {
    guard let pid = findApp(named: appName) else {
        throw AXError.appNotFound(appName)
    }
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    guard let windows = windowsRef as? [AXUIElement] else { return nil }

    for window in windows {
        if let found = findElement(in: window, identifier: identifier) {
            return (found, getFrame(found))
        }
    }
    return nil
}
```

**Step 2: Add tree/find/read/click/frame commands to main.swift**

Add cases to the switch in main.swift:

```swift
case "tree":
    let windowIndex = Int(getFlag(args, "--window") ?? "0") ?? 0
    let maxDepth = Int(getFlag(args, "--depth") ?? "5") ?? 5
    let window = try getWindowElement(appName: appName, windowIndex: windowIndex)
    let tree = buildTree(window, depth: 0, maxDepth: maxDepth)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(tree)
    print(String(data: data, encoding: .utf8)!)

case "find":
    guard let identifier = getFlag(args, "--identifier") else {
        print("Error: --identifier required")
        exit(1)
    }
    if let (element, frame) = try findInAllWindows(appName: appName, identifier: identifier) {
        let info = ElementInfo(
            role: getStringAttribute(element, kAXRoleAttribute) ?? "",
            identifier: identifier,
            title: getStringAttribute(element, kAXTitleAttribute) ?? "",
            value: getStringAttribute(element, kAXValueAttribute) ?? "",
            frame: frame,
            children: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        print(String(data: data, encoding: .utf8)!)
    } else {
        print("Element not found: \(identifier)")
        exit(1)
    }

case "read":
    guard let identifier = getFlag(args, "--identifier") else {
        print("Error: --identifier required")
        exit(1)
    }
    if let (element, _) = try findInAllWindows(appName: appName, identifier: identifier) {
        let value = getStringAttribute(element, kAXValueAttribute) ?? ""
        let title = getStringAttribute(element, kAXTitleAttribute) ?? ""
        print(value.isEmpty ? title : value)
    } else {
        print("Element not found: \(identifier)")
        exit(1)
    }

case "click":
    guard let identifier = getFlag(args, "--identifier") else {
        print("Error: --identifier required")
        exit(1)
    }
    if let (element, _) = try findInAllWindows(appName: appName, identifier: identifier) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("Clicked: \(identifier)")
    } else {
        print("Element not found: \(identifier)")
        exit(1)
    }

case "frame":
    guard let identifier = getFlag(args, "--identifier") else {
        print("Error: --identifier required")
        exit(1)
    }
    if let (_, frame) = try findInAllWindows(appName: appName, identifier: identifier) {
        print("\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))")
    } else {
        print("Element not found: \(identifier)")
        exit(1)
    }
```

**Step 3: Build and test**

Run: `cd /Users/metepolat/Developer/Remarc/tools/ax-inspect && swift build`
Expected: Build succeeds

Run: `.build/debug/ax-inspect tree --app "Remarc" --window 0 --depth 3`
Expected: JSON tree of AX elements (if app running)

**Step 4: Commit**

```bash
git add tools/ax-inspect/Sources/
git commit -m "feat: ax-inspect tree, find, read, click, frame commands"
```

---

### Task 4: Add accessibility identifiers to SwiftUI views

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CornerWidgetWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/ViewerWindowController.swift`

**Step 1: Add identifiers to SelectionTooltipView**

In `SelectionTooltipView.swift`, add `.accessibilityIdentifier("remarc.tooltip")` to the outermost view:

After `.shadow(color: .black.opacity(0.15), radius: 4, y: 2)` add:
```swift
.accessibilityIdentifier("remarc.tooltip")
```

**Step 2: Add identifiers to CommentInputView**

In `CommentInputView.swift`:

On the outer VStack (the one with `.frame(width: 320)`), after `.shadow(...)` add:
```swift
.accessibilityIdentifier("remarc.commentInput")
```

On the Save button, add:
```swift
.accessibilityIdentifier("remarc.commentInput.submitButton")
```

**Step 3: Add identifiers to CornerWidgetView**

In `CornerWidgetWindowController.swift`:

On the `collapsedView`, after `.contentShape(Capsule())` (before `.onTapGesture`), add:
```swift
.accessibilityIdentifier("remarc.cornerWidget")
```

On the comment count `Text("\(commentCount)...")`, add:
```swift
.accessibilityIdentifier("remarc.cornerWidget.commentCount")
```

On the `expandedView`, after `.shadow(...)`, add:
```swift
.accessibilityIdentifier("remarc.cornerWidget.expanded")
```

**Step 4: Add identifiers to ViewerView**

In `ViewerWindowController.swift`:

On the outermost `ZStack` (with `.frame(width: ..., height: ...)`), after `.shadow(...)` and before `.overlay(alignment: .bottom)`, add:
```swift
.accessibilityIdentifier("remarc.viewer")
```

On `commentsColumn`, add:
```swift
.accessibilityIdentifier("remarc.viewer.commentList")
```

On `detailColumn`, add:
```swift
.accessibilityIdentifier("remarc.viewer.commentDetail")
```

**Step 5: Build to verify no compile errors**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/
git commit -m "feat: add accessibility identifiers to all key SwiftUI views"
```

---

### Task 5: Create verify.sh orchestration script

**Files:**
- Create: `scripts/verify.sh`

**Step 1: Write verify.sh**

```bash
#!/bin/bash
# Remarc Verification Toolkit
# Usage: scripts/verify.sh [build|launch|screenshot|smoke-test|full]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$REPO_ROOT/app/Remarc.xcworkspace"
SCHEME="Remarc"
APP_NAME="Remarc"
SCREENSHOT_DIR="$REPO_ROOT/tests/screenshots"
AX_INSPECT="$REPO_ROOT/tools/ax-inspect/.build/debug/ax-inspect"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
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

ensure_ax_inspect() {
    if [ ! -f "$AX_INSPECT" ]; then
        log_info "Building ax-inspect..."
        (cd "$REPO_ROOT/tools/ax-inspect" && swift build -q)
    fi
}

cmd_build() {
    log_info "Building $SCHEME..."
    xcodebuild build \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -quiet 2>&1 | tail -3
    log_ok "Build succeeded"
}

find_app_path() {
    # Find the most recently built .app in DerivedData
    find "$DERIVED_DATA" -path "*/Build/Products/Debug/${APP_NAME}.app" -maxdepth 5 2>/dev/null | head -1
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

cmd_smoke_test() {
    ensure_ax_inspect
    log_info "Running smoke test..."

    # 1. Check app is running
    if ! pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        log_fail "App is not running"
        exit 1
    fi
    log_ok "App is running"

    # 2. List windows
    local windows
    windows=$("$AX_INSPECT" list-windows --app "$APP_NAME" 2>&1) || true
    echo "$windows"
    log_ok "Windows listed"

    # 3. Screenshot full screen
    cmd_screenshot "smoke-fullscreen"

    # 4. Check debug log for startup messages
    if [ -f "$DEBUG_LOG" ]; then
        if grep -q "AppController setup complete" "$DEBUG_LOG"; then
            log_ok "App setup completed (from debug log)"
        else
            log_info "Debug log exists but setup message not found"
        fi
    fi

    log_ok "Smoke test complete"
}

cmd_full() {
    cmd_build
    cmd_launch
    sleep 2  # Extra settle time
    cmd_smoke_test
}

# Main dispatch
case "${1:-help}" in
    build)      cmd_build ;;
    launch)     cmd_launch ;;
    screenshot) shift; cmd_screenshot "$@" ;;
    smoke-test) cmd_smoke_test ;;
    full)       cmd_full ;;
    help|*)
        echo "Usage: verify.sh <command>"
        echo ""
        echo "Commands:"
        echo "  build        Build the app (Debug)"
        echo "  launch       Kill existing & launch fresh build"
        echo "  screenshot   Take screenshot [label] [--region x,y,w,h]"
        echo "  smoke-test   Quick check: app running, windows visible"
        echo "  full         Build + launch + smoke test"
        echo ""
        echo "Examples:"
        echo "  scripts/verify.sh full"
        echo "  scripts/verify.sh screenshot corner-widget"
        echo "  scripts/verify.sh screenshot viewer --region 100,200,800,550"
        ;;
esac
```

**Step 2: Make it executable**

```bash
chmod +x /Users/metepolat/Developer/Remarc/scripts/verify.sh
```

**Step 3: Test help output**

Run: `/Users/metepolat/Developer/Remarc/scripts/verify.sh help`
Expected: Usage message printed

**Step 4: Commit**

```bash
git add scripts/verify.sh
git commit -m "feat: add verify.sh orchestration script for visual verification"
```

---

### Task 6: End-to-end integration test

**Files:** None (testing only)

**Step 1: Build ax-inspect**

Run: `cd /Users/metepolat/Developer/Remarc/tools/ax-inspect && swift build`
Expected: Build succeeds

**Step 2: Build the app**

Run: `/Users/metepolat/Developer/Remarc/scripts/verify.sh build`
Expected: `[OK] Build succeeded`

**Step 3: Launch the app**

Run: `/Users/metepolat/Developer/Remarc/scripts/verify.sh launch`
Expected: `[OK] App launched (pid: XXXXX)`

**Step 4: Run smoke test**

Run: `/Users/metepolat/Developer/Remarc/scripts/verify.sh smoke-test`
Expected: Windows listed, screenshot taken, all [OK]

**Step 5: Test ax-inspect commands**

Run: `tools/ax-inspect/.build/debug/ax-inspect list-windows --app Remarc`
Expected: JSON array of visible windows

Run: `tools/ax-inspect/.build/debug/ax-inspect tree --app Remarc --window 0 --depth 3`
Expected: JSON tree showing AX elements

**Step 6: Take targeted screenshot**

If a window is visible, get its frame and capture:
```bash
FRAME=$(tools/ax-inspect/.build/debug/ax-inspect frame --app Remarc --identifier remarc.cornerWidget 2>/dev/null)
if [ -n "$FRAME" ]; then
    scripts/verify.sh screenshot corner-widget --region "$FRAME"
fi
```

**Step 7: Verify screenshot is viewable**

Use Claude's Read tool on the saved screenshot PNG to confirm the image is readable.

**Step 8: Commit (no code changes, but confirm everything works)**

No commit needed unless fixes were required.

---

### Task 7: Document usage in CLAUDE.md or memory

**Files:**
- Modify or create: project documentation noting the verification workflow

**Step 1: Save verification workflow to Claude memory**

Document the standard verification commands in `/Users/metepolat/.claude/projects/-Users-metepolat-Developer-Remarc/memory/MEMORY.md`:

```markdown
## Verification Toolkit

After making code changes to Remarc, use these commands to verify:

### Quick check (build + launch + smoke test):
```
scripts/verify.sh full
```

### Individual commands:
```
scripts/verify.sh build          # Build Debug
scripts/verify.sh launch         # Kill & relaunch
scripts/verify.sh smoke-test     # Check windows + screenshot
scripts/verify.sh screenshot <label> [--region x,y,w,h]
```

### AX inspection:
```
tools/ax-inspect/.build/debug/ax-inspect list-windows
tools/ax-inspect/.build/debug/ax-inspect tree --window 0 --depth 3
tools/ax-inspect/.build/debug/ax-inspect find --identifier remarc.cornerWidget
tools/ax-inspect/.build/debug/ax-inspect read --identifier remarc.cornerWidget.commentCount
tools/ax-inspect/.build/debug/ax-inspect click --identifier remarc.commentInput.submitButton
tools/ax-inspect/.build/debug/ax-inspect frame --identifier remarc.viewer
```

### Accessibility identifiers:
- `remarc.tooltip` — Selection tooltip
- `remarc.commentInput` — Comment input panel
- `remarc.commentInput.submitButton` — Submit button
- `remarc.cornerWidget` — Corner widget (collapsed)
- `remarc.cornerWidget.expanded` — Corner widget (expanded)
- `remarc.cornerWidget.commentCount` — Comment count label
- `remarc.viewer` — Viewer window
- `remarc.viewer.commentList` — Comment list
- `remarc.viewer.commentDetail` — Detail pane

### Debug log: `/tmp/remarc_debug.log`
### Screenshots: `tests/screenshots/` (gitignored)
```

**Step 2: Commit**

No git commit needed for memory files.
