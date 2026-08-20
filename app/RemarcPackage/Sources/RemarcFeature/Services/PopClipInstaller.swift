import AppKit

/// Detects PopClip and hands it the bundled extension package.
///
/// Detection is a synchronous LaunchServices lookup, not a CLI spawn, so none of
/// the `ProcessRunner` rules that govern the Claude Code and Codex plugin
/// detectors apply here.
@MainActor
public final class PopClipInstaller {
    public static let shared = PopClipInstaller()
    public static let popClipBundleIdentifier = "com.pilotmoon.popclip"
    public static let packageName = "Remarc.popclipext"

    private init() {}

    public static func isInstalled(
        lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> Bool {
        lookup(popClipBundleIdentifier) != nil
    }

    public static func bundledPackageURL(in resourcesDirectory: URL) -> URL {
        resourcesDirectory.appendingPathComponent(packageName)
    }

    /// Hands the bundled package to PopClip, which installs it.
    ///
    /// No confirmation dialog appears: PopClip gates its unsigned-extension
    /// warning on capabilities (Shell Script actions, AppleScript actions, or
    /// declared entitlements) and this extension declares none. Verified
    /// directly, including with a real `com.apple.quarantine` xattr set, so
    /// quarantine is not the gate either. Repeat installs are idempotent -
    /// PopClip keeps one entry per identifier.
    ///
    /// Returns false when the package is missing from this build.
    @discardableResult
    public func install() -> Bool {
        guard let resources = Bundle.main.resourceURL else {
            debugLog("PopClipInstaller: no resource URL")
            return false
        }
        let package = Self.bundledPackageURL(in: resources)
        guard FileManager.default.fileExists(atPath: package.path) else {
            debugLog("PopClipInstaller: bundled package missing at \(package.path)")
            return false
        }
        debugLog("PopClipInstaller: opening \(package.path)")
        return NSWorkspace.shared.open(package)
    }
}
