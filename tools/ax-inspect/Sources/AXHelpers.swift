import AppKit
import ApplicationServices

// MARK: - Error Handling

enum AXInspectError: Error, CustomStringConvertible {
    case appNotFound(String)
    case axError(String)
    case attributeError(String)

    var description: String {
        switch self {
        case .appNotFound(let name):
            return "Application not found: \(name)"
        case .axError(let message):
            return "Accessibility error: \(message)"
        case .attributeError(let message):
            return "Attribute error: \(message)"
        }
    }
}

// MARK: - Data Types

struct FrameInfo: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct WindowInfo: Encodable {
    let index: Int
    let title: String?
    let role: String?
    let subrole: String?
    let frame: FrameInfo?
    let isVisible: Bool
}

struct ElementInfo: Encodable {
    let role: String?
    let identifier: String?
    let title: String?
    let value: String?
    let frame: FrameInfo?
    let children: [ElementInfo]?
}

// MARK: - AX Attribute Helpers

func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let stringValue = value as? String else {
        return nil
    }
    return stringValue
}

func getFrame(_ element: AXUIElement) -> FrameInfo? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as String as CFString, &positionValue)
    let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as String as CFString, &sizeValue)

    guard posResult == .success, sizeResult == .success else {
        return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero

    // AXValueGetValue extracts the CGPoint/CGSize from the AXValue wrapper
    guard let posAXValue = positionValue,
          AXValueGetValue(posAXValue as! AXValue, .cgPoint, &point),
          let sizeAXValue = sizeValue,
          AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &size) else {
        return nil
    }

    return FrameInfo(
        x: Double(point.x),
        y: Double(point.y),
        width: Double(size.width),
        height: Double(size.height)
    )
}

// MARK: - App Discovery

/// Find a running application's PID by name using NSWorkspace.
/// Uses `nonisolated(unsafe)` to access NSWorkspace.shared outside the main actor,
/// which is safe here because we only read from it and this is a short-lived CLI tool.
func findApp(named name: String) -> pid_t? {
    nonisolated(unsafe) let workspace = NSWorkspace.shared
    let apps = workspace.runningApplications
    let match = apps.first { app in
        app.localizedName == name || app.bundleIdentifier?.contains(name) == true
    }
    return match?.processIdentifier
}

// MARK: - Window Listing

/// List all windows for the given app name using the Accessibility API.
func listWindows(appName: String) throws -> [WindowInfo] {
    guard let pid = findApp(named: appName) else {
        throw AXInspectError.appNotFound(appName)
    }

    let appElement = AXUIElementCreateApplication(pid)

    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let windowArray = windowsRef as? [AXUIElement] else {
        // No windows is not necessarily an error — the app might just have none open
        if result == .success || result == .noValue {
            return []
        }
        throw AXInspectError.axError(
            "Failed to get windows attribute (error: \(result.rawValue))"
        )
    }

    var windows: [WindowInfo] = []
    for (index, window) in windowArray.enumerated() {
        let title = getStringAttribute(window, kAXTitleAttribute as String)
        let role = getStringAttribute(window, kAXRoleAttribute as String)
        let subrole = getStringAttribute(window, kAXSubroleAttribute as String)
        let frame = getFrame(window)

        // Check visibility via the minimized attribute
        var minimizedRef: CFTypeRef?
        let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
        let isMinimized = (minResult == .success) && (minimizedRef as? Bool == true)

        let info = WindowInfo(
            index: index,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isVisible: !isMinimized
        )
        windows.append(info)
    }

    return windows
}

// MARK: - Window Element Access

/// Get a specific window's AXUIElement by index for the given app name.
func getWindowElement(appName: String, windowIndex: Int) throws -> AXUIElement {
    guard let pid = findApp(named: appName) else {
        throw AXInspectError.appNotFound(appName)
    }

    let appElement = AXUIElementCreateApplication(pid)

    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as String as CFString, &windowsRef)

    guard result == .success, let windowArray = windowsRef as? [AXUIElement] else {
        throw AXInspectError.axError(
            "Failed to get windows attribute (error: \(result.rawValue))"
        )
    }

    guard windowIndex >= 0 && windowIndex < windowArray.count else {
        throw AXInspectError.axError(
            "Window index \(windowIndex) out of range (app has \(windowArray.count) window(s))"
        )
    }

    return windowArray[windowIndex]
}

// MARK: - Tree Building

/// Recursively build an ElementInfo tree from an AXUIElement.
/// Walks children via kAXChildrenAttribute up to maxDepth levels deep.
func buildTree(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 5) -> ElementInfo {
    let role = getStringAttribute(element, kAXRoleAttribute as String)
    let identifier = getStringAttribute(element, kAXIdentifierAttribute as String)
    let title = getStringAttribute(element, kAXTitleAttribute as String)
    let value: String? = {
        var ref: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, kAXValueAttribute as String as CFString, &ref)
        guard res == .success, let v = ref else { return nil }
        return "\(v)"
    }()
    let frame = getFrame(element)

    var childInfos: [ElementInfo]? = nil
    if depth < maxDepth {
        var childrenRef: CFTypeRef?
        let childResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as String as CFString, &childrenRef)
        if childResult == .success, let childArray = childrenRef as? [AXUIElement], !childArray.isEmpty {
            childInfos = childArray.map { buildTree($0, depth: depth + 1, maxDepth: maxDepth) }
        }
    }

    return ElementInfo(
        role: role,
        identifier: identifier,
        title: title,
        value: value,
        frame: frame,
        children: childInfos
    )
}

// MARK: - Element Finding

/// Recursively search for an element with a matching kAXIdentifierAttribute.
/// Returns the first matching AXUIElement, or nil if not found.
func findElement(in element: AXUIElement, identifier: String) -> AXUIElement? {
    let currentId = getStringAttribute(element, kAXIdentifierAttribute as String)
    if currentId == identifier {
        return element
    }

    var childrenRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as String as CFString, &childrenRef)
    guard result == .success, let childArray = childrenRef as? [AXUIElement] else {
        return nil
    }

    for child in childArray {
        if let found = findElement(in: child, identifier: identifier) {
            return found
        }
    }

    return nil
}

/// Search all windows of the given app for an element with the matching identifier.
/// Returns a tuple of the found element and its frame, or nil if not found.
func findInAllWindows(appName: String, identifier: String) throws -> (AXUIElement, FrameInfo?)? {
    guard let pid = findApp(named: appName) else {
        throw AXInspectError.appNotFound(appName)
    }

    let appElement = AXUIElementCreateApplication(pid)

    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as String as CFString, &windowsRef)

    guard result == .success, let windowArray = windowsRef as? [AXUIElement] else {
        if result == .success || result == .noValue {
            return nil
        }
        throw AXInspectError.axError(
            "Failed to get windows attribute (error: \(result.rawValue))"
        )
    }

    for window in windowArray {
        if let found = findElement(in: window, identifier: identifier) {
            let frame = getFrame(found)
            return (found, frame)
        }
    }

    return nil
}
