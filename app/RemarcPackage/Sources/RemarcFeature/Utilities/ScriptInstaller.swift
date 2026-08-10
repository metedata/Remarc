import Foundation

/// Installs bundled scripts to a stable location in Application Support
/// so that MCP and hook paths survive app translocation and relocation.
enum ScriptInstaller {
    static let scriptsDirectoryURL: URL =
        remarcAppSupportURL.appendingPathComponent("scripts", isDirectory: true)

    private static let resources: [(name: String, ext: String)] = [
        ("remarc-mcp", "js"),
    ]

    // Bundle path is constant for the process lifetime.
    private static let parentDirectories: [URL] = {
        var dir = URL(fileURLWithPath: Bundle.main.bundlePath)
        var dirs: [URL] = []
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            dirs.append(dir)
        }
        return dirs
    }()

    /// Copies bundled scripts to App Support. Call on every launch.
    @discardableResult
    static func installBundledScripts() -> Bool {
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            debugLog("ScriptInstaller: Failed to create scripts directory: \(error)")
            return false
        }

        var allSucceeded = true
        for resource in resources {
            guard let sourceURL = Bundle.main.url(forResource: resource.name, withExtension: resource.ext) else {
                debugLog("ScriptInstaller: Bundle resource not found: \(resource.name).\(resource.ext)")
                allSucceeded = false
                continue
            }

            let destURL = scriptsDirectoryURL.appendingPathComponent("\(resource.name).\(resource.ext)")

            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: sourceURL, to: destURL)

                if resource.ext == "sh" {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                }
            } catch {
                debugLog("ScriptInstaller: Failed to install \(resource.name).\(resource.ext): \(error)")
                allSucceeded = false
            }
        }

        if allSucceeded {
            debugLog("ScriptInstaller: All scripts installed to \(scriptsDirectoryURL.path)")
        }
        return allSucceeded
    }

    /// Two-tier path resolution: source tree (dev) -> bundle.
    ///
    /// The App Support copy used to sit between these, and it is how a release
    /// build ended up executing a server frozen at whatever version last
    /// managed to install itself. `installBundledScripts()` has no call site,
    /// so nothing refreshed that copy; meanwhile a release has no source tree,
    /// so the stale copy won every time. Sparkle replaces `Remarc.app`, not
    /// files living outside it, so app updates could not fix it either.
    ///
    /// The bundle is the only copy that is signed, notarized, and replaced
    /// atomically by an update, so it is the only one worth resolving to.
    static func resolvedPath(source relativePath: String, bundleName: String, bundleExt: String) -> String? {
        if let path = sourceTreePath(relativePath) {
            return path
        }

        return Bundle.main.url(forResource: bundleName, withExtension: bundleExt)?.path
    }

    /// Delete the App Support script copies this app used to resolve to.
    ///
    /// They are unreachable now, but they are also executable JavaScript that
    /// predates every data-integrity fix, and any config still pointing at one
    /// keeps running it. Removing them is what actually retires that path.
    @discardableResult
    static func removeStaleInstalledScripts() -> Int {
        let fm = FileManager.default
        var removed = 0
        for resource in resources {
            let url = scriptsDirectoryURL.appendingPathComponent("\(resource.name).\(resource.ext)")
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
                debugLog("ScriptInstaller: removed stale \(url.lastPathComponent)")
            } catch {
                debugLog("ScriptInstaller: could not remove \(url.lastPathComponent): \(error)")
            }
        }
        return removed
    }

    /// Walks up from the app bundle looking for a source tree file.
    /// Returns the shallowest match (project root over worktree).
    static func sourceTreePath(_ relativePath: String) -> String? {
        var best: String?
        for dir in parentDirectories {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                best = candidate.path
            }
        }
        return best
    }
}
