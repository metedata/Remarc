import Foundation

/// The detected Remarc integration state for one OMP profile.
public struct OMPProfileState: Equatable, Sendable {
    public let name: String
    public let hasRemarcArtifacts: Bool
    public let remarcConfigured: Bool
    public let hasWakeArtifacts: Bool
    public let wakeConfigured: Bool

    public init(
        name: String,
        hasRemarcArtifacts: Bool,
        remarcConfigured: Bool,
        hasWakeArtifacts: Bool,
        wakeConfigured: Bool
    ) {
        self.name = name
        self.hasRemarcArtifacts = hasRemarcArtifacts
        self.remarcConfigured = remarcConfigured
        self.hasWakeArtifacts = hasWakeArtifacts
        self.wakeConfigured = wakeConfigured
    }
}

/// The detected OMP integration state across all local profiles.
public struct OMPIntegrationState: Equatable, Sendable {
    public let profiles: [OMPProfileState]

    public init(profiles: [OMPProfileState]) {
        self.profiles = profiles.sorted { lhs, rhs in
            if lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame {
                return lhs.name < rhs.name
            }
            if lhs.name.caseInsensitiveCompare("Default") == .orderedSame {
                return true
            }
            if rhs.name.caseInsensitiveCompare("Default") == .orderedSame {
                return false
            }
            return lhs.name.caseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public var remarcProfiles: [String] {
        profiles.filter(\.remarcConfigured).map(\.name)
    }

    public var wakeProfiles: [String] {
        profiles.filter(\.wakeConfigured).map(\.name)
    }

    public var hasRemarcArtifacts: Bool {
        profiles.contains(where: \.hasRemarcArtifacts)
    }

    public var hasWakeArtifacts: Bool {
        profiles.contains(where: \.hasWakeArtifacts)
    }

    public var remarcProfileSummary: String? {
        Self.summary(remarcProfiles)
    }

    public var wakeProfileSummary: String? {
        Self.summary(wakeProfiles)
    }

    private static func summary(_ names: [String]) -> String? {
        names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

/// Reads OMP profile directories without invoking an external process.
public enum OMPIntegrationDetector {
    public static func read(
        ompDirectory: URL,
        fileManager: FileManager = .default
    ) -> OMPIntegrationState {
        let profiles = profileDirectories(in: ompDirectory, fileManager: fileManager)
            .map { profile in
                profileState(
                    name: profile.name,
                    agentDirectory: profile.directory,
                    fileManager: fileManager
                )
            }

        return OMPIntegrationState(profiles: profiles)
    }

    private static func profileDirectories(
        in ompDirectory: URL,
        fileManager: FileManager
    ) -> [(name: String, directory: URL)] {
        var profiles: [(name: String, directory: URL)] = []
        let defaultDirectory = ompDirectory.appendingPathComponent("agent", isDirectory: true)
        if isDirectory(defaultDirectory, fileManager: fileManager) {
            profiles.append(("Default", defaultDirectory))
        }

        let namedProfilesDirectory = ompDirectory.appendingPathComponent("profiles", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: namedProfilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return profiles
        }

        for entry in entries {
            let agentDirectory = entry.appendingPathComponent("agent", isDirectory: true)
            guard isDirectory(agentDirectory, fileManager: fileManager) else { continue }
            profiles.append((entry.lastPathComponent, agentDirectory))
        }
        return profiles
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolvedURL.path),
              let isDirectory = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        else {
            return false
        }
        return isDirectory
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolvedURL.path),
              let isRegularFile = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
        else {
            return false
        }
        return isRegularFile
    }

    private static func profileState(
        name: String,
        agentDirectory: URL,
        fileManager: FileManager
    ) -> OMPProfileState {
        let mcpURL = agentDirectory.appendingPathComponent("mcp.json")
        let remarcSkillURL = agentDirectory.appendingPathComponent("skills/remarc", isDirectory: true)
        let wakeExtensionURL = agentDirectory.appendingPathComponent("extensions/remarc-wake/index.ts")
        let wakeSkillURL = agentDirectory.appendingPathComponent("skills/remarc-review", isDirectory: true)

        let hasMCP = fileManager.fileExists(atPath: mcpURL.path)
        let hasRemarcSkill = fileManager.fileExists(atPath: remarcSkillURL.path)
        let hasWakeExtension = fileManager.fileExists(atPath: wakeExtensionURL.path)
        let hasWakeSkill = fileManager.fileExists(atPath: wakeSkillURL.path)
        let hasRemarcArtifacts = hasMCP || hasRemarcSkill
        let hasWakeArtifacts = hasWakeExtension || hasWakeSkill
        let remarcConfigured = hasMCP
            && isDirectory(remarcSkillURL, fileManager: fileManager)
            && validRemarcMCP(at: mcpURL)
        let wakeConfigured = remarcConfigured
            && isRegularFile(wakeExtensionURL, fileManager: fileManager)
            && isDirectory(wakeSkillURL, fileManager: fileManager)

        return OMPProfileState(
            name: name,
            hasRemarcArtifacts: hasRemarcArtifacts,
            remarcConfigured: remarcConfigured,
            hasWakeArtifacts: hasWakeArtifacts,
            wakeConfigured: wakeConfigured
        )
    }

    private static func validRemarcMCP(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let remarc = servers["remarc"] as? [String: Any],
              remarc["type"] as? String == "stdio",
              remarc["command"] as? String == "node",
              let args = remarc["args"] as? [String],
              args.count == 1,
              let firstArgument = args.first,
              URL(fileURLWithPath: firstArgument).lastPathComponent == "remarc-mcp.js"
        else {
            return false
        }

        if let disabledServersValue = root["disabledServers"] {
            guard let disabledServers = disabledServersValue as? [String],
                  !disabledServers.contains("remarc")
            else {
                return false
            }
        }
        if let enabledValue = remarc["enabled"] {
            guard let enabled = enabledValue as? Bool, enabled else {
                return false
            }
        }
        return true
    }
}
