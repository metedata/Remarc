import Foundation

public let remarcScreenshotDirectoryPathKey = "screenshotDirectoryPath"

/// Tests use a private defaults suite as well as a temporary file root. Never
/// clear the running app's screenshot setting to isolate a storage test.
nonisolated(unsafe) var remarcScreenshotDefaultsOverride: UserDefaults?

var remarcScreenshotDefaults: UserDefaults {
    remarcScreenshotDefaultsOverride ?? .standard
}

enum ScreenshotStorage {
    static let knownDirectoriesKey = "screenshotStorageDirectories"

    enum StorageError: LocalizedError {
        case invalidDirectory
        case unavailableDirectory(String)

        var errorDescription: String? {
            switch self {
            case .invalidDirectory:
                return "Choose a folder on this Mac."
            case .unavailableDirectory(let path):
                return "The screenshot folder is unavailable: \(path). Reconnect it or choose another folder in Settings."
            }
        }
    }

    static var defaultDirectory: URL {
        remarcAppSupportURL.appendingPathComponent("images", isDirectory: true)
    }

    /// Called only for an explicit folder choice. Validate the actual write
    /// before changing preferences, and remember canonical roots independently
    /// of comments or lease records, which can be edited by integrations.
    @discardableResult
    static func configure(directory: URL?, defaults: UserDefaults) throws -> String {
        guard directory == nil || directory?.isFileURL == true else {
            throw StorageError.invalidDirectory
        }
        let selected = (directory ?? defaultDirectory)
            .standardizedFileURL.resolvingSymlinksInPath()
        let fallback = defaultDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let isDefault = selected.path == fallback.path
        if isDefault {
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        }
        try requireDirectory(selected)
        let probe = selected.appendingPathComponent(".remarc-write-test-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: probe) }
        try FileManager.default.removeItem(at: probe)

        var known = defaults.stringArray(forKey: knownDirectoriesKey) ?? []
        // Preserve the previously configured root on reset, including a folder
        // selected by an earlier build before the history preference existed.
        if let previous = defaults.string(forKey: remarcScreenshotDirectoryPathKey),
           previous.hasPrefix("/"), !known.contains(previous) {
            known.append(previous)
        }
        if !isDefault, !known.contains(selected.path) {
            known.append(selected.path)
        }
        defaults.set(known, forKey: knownDirectoriesKey)
        let path = isDefault ? "" : selected.path
        if isDefault {
            defaults.removeObject(forKey: remarcScreenshotDirectoryPathKey)
        } else {
            defaults.set(path, forKey: remarcScreenshotDirectoryPathKey)
        }
        return path
    }

    static func requireDirectory(_ url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw StorageError.unavailableDirectory(url.path)
        }
    }

    /// The stored roots are already canonical. Do not resolve them again: a
    /// former storage folder replaced with a symlink must not grant ownership
    /// of a different directory.
    static var ownedDirectories: [URL] {
        var paths = remarcScreenshotDefaults.stringArray(forKey: knownDirectoriesKey) ?? []
        if let current = remarcScreenshotDefaults.string(forKey: remarcScreenshotDirectoryPathKey),
           !current.isEmpty {
            paths.append(current)
        }
        var directories = [defaultDirectory.standardizedFileURL.resolvingSymlinksInPath()]
        for path in paths where path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if !directories.contains(where: { $0.path == url.path }) {
                directories.append(url)
            }
        }
        return directories
    }
}

var remarcImagesDirectoryURL: URL {
    if let path = remarcScreenshotDefaults.string(forKey: remarcScreenshotDirectoryPathKey),
       !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return ScreenshotStorage.defaultDirectory
}

/// Existing relative paths always resolve under App Support. Custom paths
/// remain absolute, so changing the setting never redirects an old comment.
public func resolveImagePath(_ storedPath: String) -> URL {
    if storedPath.hasPrefix("/") {
        return URL(fileURLWithPath: storedPath)
    }
    return remarcAppSupportURL.appendingPathComponent(storedPath)
}

func remarcNewScreenshotStoredPath() throws -> String {
    // Read once: a concurrent Settings change cannot mix one folder with
    // another folder's relative/absolute representation.
    let custom = remarcScreenshotDefaults.string(forKey: remarcScreenshotDirectoryPathKey) ?? ""
    let filename = "\(UUID().uuidString).png"
    if !custom.isEmpty {
        guard custom.hasPrefix("/") else { throw ScreenshotStorage.StorageError.invalidDirectory }
        let directory = URL(fileURLWithPath: custom, isDirectory: true)
        try ScreenshotStorage.requireDirectory(directory)
        let path = directory.appendingPathComponent(filename).path
        guard remarcOwnedImageURL(for: path) != nil else {
            throw ScreenshotStorage.StorageError.unavailableDirectory(custom)
        }
        // Do not recreate a missing custom folder (for example an unmounted
        // drive) or silently save somewhere the user's agent cannot access.
        return path
    }
    try FileManager.default.createDirectory(
        at: ScreenshotStorage.defaultDirectory, withIntermediateDirectories: true)
    return "images/\(filename)"
}

func writeNewScreenshotData(_ data: Data) throws -> String {
    let stored = try remarcNewScreenshotStoredPath()
    try data.write(to: resolveImagePath(stored), options: .atomic)
    return stored
}

func isRemarcManagedImageFilename(_ name: String) -> Bool {
    for suffix in [".base.png", ".marks.json", ".png"] where name.hasSuffix(suffix) {
        return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
    }
    return false
}

/// Reads may refer to external images, but writes and deletes require a known
/// root. Custom folders also require Remarc's UUID filenames because they may
/// contain unrelated user files. The dedicated default folder keeps legacy
/// filename compatibility.
func remarcOwnedImageURL(for storedPath: String) -> URL? {
    let candidate = resolveImagePath(storedPath).standardizedFileURL
    let target = candidate.resolvingSymlinksInPath()
    let parent = target.deletingLastPathComponent()
    let fallback = ScreenshotStorage.defaultDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard ScreenshotStorage.ownedDirectories.contains(where: { $0.path == parent.path }) else {
        return nil
    }
    let originalParent = candidate.deletingLastPathComponent().path
    let originalDefault = ScreenshotStorage.defaultDirectory.standardizedFileURL.path
    if originalParent != originalDefault, originalParent != parent.path {
        return nil
    }
    // Refuse file symlinks even when they point at another known storage root.
    guard candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(candidate.lastPathComponent).path == target.path else { return nil }
    if parent.path != fallback.path, !isRemarcManagedImageFilename(target.lastPathComponent) {
        return nil
    }
    return target
}
