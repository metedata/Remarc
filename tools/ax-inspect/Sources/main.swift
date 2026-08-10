import ApplicationServices
import Foundation

// MARK: - Argument Parsing Helpers

/// Extract the value for a --flag from command-line arguments.
/// Returns the default value if the flag is not found.
func getFlag(_ flag: String, _ defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: flag),
          flagIndex + 1 < args.count else {
        return defaultValue
    }
    return args[flagIndex + 1]
}

/// Extract the value for a --flag from command-line arguments.
/// Returns nil if the flag is not found.
func getOptionalFlag(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: flag),
          flagIndex + 1 < args.count else {
        return nil
    }
    return args[flagIndex + 1]
}

// MARK: - Usage

func printUsage() {
    let usage = """
    ax-inspect — Accessibility inspector for macOS apps

    Usage: ax-inspect <command> [options]

    Commands:
      list-windows   List all windows for an app
      tree           Print the accessibility tree for a window
      find           Find an element by accessibility identifier
      read           Read the value of an element
      click          Perform a click action on an element
      frame          Get the frame (position & size) of an element

    Options:
      --app <name>         Target application name (default: "Remarc")
      --window <index>     Window index for tree command (default: 0)
      --depth <n>          Max tree depth (default: 5)
      --identifier <id>    Accessibility identifier (required for find/read/click/frame)

    Examples:
      ax-inspect list-windows
      ax-inspect list-windows --app Safari
      ax-inspect tree --app Remarc --window 0 --depth 3
      ax-inspect find --identifier myButton
      ax-inspect read --identifier myTextField
      ax-inspect click --identifier myButton
      ax-inspect frame --identifier myButton
    """
    print(usage)
}

// MARK: - Commands

func runListWindows() {
    let appName = getFlag("--app", "Remarc")

    do {
        let windows = try listWindows(appName: appName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(windows)

        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runTree() {
    let appName = getFlag("--app", "Remarc")
    let windowIndex = Int(getFlag("--window", "0")) ?? 0
    let maxDepth = Int(getFlag("--depth", "5")) ?? 5

    do {
        let window = try getWindowElement(appName: appName, windowIndex: windowIndex)
        let tree = buildTree(window, depth: 0, maxDepth: maxDepth)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tree)

        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runFind() {
    let appName = getFlag("--app", "Remarc")
    guard let identifier = getOptionalFlag("--identifier") else {
        fputs("Error: --identifier is required for find command\n", stderr)
        exit(1)
    }

    do {
        guard let (element, frame) = try findInAllWindows(appName: appName, identifier: identifier) else {
            fputs("Error: element with identifier \"\(identifier)\" not found\n", stderr)
            exit(1)
        }

        let role = getStringAttribute(element, kAXRoleAttribute as String)
        let title = getStringAttribute(element, kAXTitleAttribute as String)
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as String as CFString, &valueRef)
        let value: String? = (valueResult == .success && valueRef != nil) ? "\(valueRef!)" : nil

        let info = ElementInfo(
            role: role,
            identifier: identifier,
            title: title,
            value: value,
            frame: frame,
            children: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)

        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runRead() {
    let appName = getFlag("--app", "Remarc")
    guard let identifier = getOptionalFlag("--identifier") else {
        fputs("Error: --identifier is required for read command\n", stderr)
        exit(1)
    }

    do {
        guard let (element, _) = try findInAllWindows(appName: appName, identifier: identifier) else {
            fputs("Error: element with identifier \"\(identifier)\" not found\n", stderr)
            exit(1)
        }

        // Try value first, fall back to title
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as String as CFString, &valueRef)
        if valueResult == .success, let v = valueRef {
            let str = "\(v)"
            if !str.isEmpty {
                print(str)
                return
            }
        }

        let title = getStringAttribute(element, kAXTitleAttribute as String)
        if let title = title, !title.isEmpty {
            print(title)
            return
        }

        // No value or title available — print empty string
        print("")
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runClick() {
    let appName = getFlag("--app", "Remarc")
    guard let identifier = getOptionalFlag("--identifier") else {
        fputs("Error: --identifier is required for click command\n", stderr)
        exit(1)
    }

    do {
        guard let (element, _) = try findInAllWindows(appName: appName, identifier: identifier) else {
            fputs("Error: element with identifier \"\(identifier)\" not found\n", stderr)
            exit(1)
        }

        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressResult == .success {
            print("Clicked element with identifier \"\(identifier)\"")
        } else {
            fputs("Error: failed to click element (error: \(pressResult.rawValue))\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runFrame() {
    let appName = getFlag("--app", "Remarc")
    guard let identifier = getOptionalFlag("--identifier") else {
        fputs("Error: --identifier is required for frame command\n", stderr)
        exit(1)
    }

    do {
        guard let (_, frame) = try findInAllWindows(appName: appName, identifier: identifier) else {
            fputs("Error: element with identifier \"\(identifier)\" not found\n", stderr)
            exit(1)
        }

        guard let frame = frame else {
            fputs("Error: element has no frame\n", stderr)
            exit(1)
        }

        // Output as x,y,width,height (comma-separated integers) for screencapture -R
        print("\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))")
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

func runClickAt() {
    guard let coordStr = getOptionalFlag("--at") else {
        fputs("Error: --at x,y is required for click-at command\n", stderr)
        exit(1)
    }
    let parts = coordStr.split(separator: ",")
    guard parts.count == 2,
          let x = Double(parts[0]),
          let y = Double(parts[1]) else {
        fputs("Error: --at must be x,y coordinates (e.g., --at 100,200)\n", stderr)
        exit(1)
    }

    let point = CGPoint(x: x, y: y)

    // CGEvent-based mouse click
    if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
       let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between down and up
        mouseUp.post(tap: .cghidEventTap)
        print("Clicked at (\(Int(x)), \(Int(y)))")
    } else {
        fputs("Error: failed to create mouse events\n", stderr)
        exit(1)
    }
}

func runType() {
    guard let text = getOptionalFlag("--text") else {
        fputs("Error: --text is required for type command\n", stderr)
        exit(1)
    }

    // Type each character using CGEvent key events
    for char in text {
        let str = String(char)
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            let utf16 = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
        }
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            event.post(tap: .cghidEventTap)
        }
        usleep(10_000) // 10ms between characters
    }
    print("Typed: \(text)")
}

func runKey() {
    guard let keyName = getOptionalFlag("--key") else {
        fputs("Error: --key is required for key command\n", stderr)
        exit(1)
    }

    let keyCode: CGKeyCode
    switch keyName.lowercased() {
    case "return", "enter": keyCode = 36
    case "escape", "esc": keyCode = 53
    case "tab": keyCode = 48
    case "space": keyCode = 49
    case "delete", "backspace": keyCode = 51
    default:
        fputs("Error: unknown key \"\(keyName)\". Supported: return, escape, tab, space, delete\n", stderr)
        exit(1)
    }

    if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
       let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        print("Pressed key: \(keyName)")
    } else {
        fputs("Error: failed to create key events\n", stderr)
        exit(1)
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : nil

switch command {
case "list-windows":
    runListWindows()
case "tree":
    runTree()
case "find":
    runFind()
case "read":
    runRead()
case "click":
    runClick()
case "frame":
    runFrame()
case "click-at":
    runClickAt()
case "type":
    runType()
case "key":
    runKey()
case nil:
    printUsage()
default:
    fputs("Unknown command: \(command!)\n\n", stderr)
    printUsage()
    exit(1)
}
