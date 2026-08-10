import Foundation

public enum CursorMCPInstaller {
    public enum Result: Equatable, Sendable {
        case installed
        case updated
        case unchanged
        case skippedNoNode
        case skippedHarnessAbsent
        case failed(String)
    }

    private enum InstallError: LocalizedError {
        case rootNotObject
        case mcpServersNotObject

        var errorDescription: String? {
            switch self {
            case .rootNotObject:
                return "~/.cursor/mcp.json does not parse as a JSON object"
            case .mcpServersNotObject:
                return "~/.cursor/mcp.json `mcpServers` is not an object"
            }
        }
    }

    private static let nodePlaceholder = "<path-to-node>"
    private static let mcpPlaceholder = "<path-to-remarc-mcp>"

    private static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor/mcp.json")
    }

    public static func install(force: Bool = false) async -> Result {
        if !force {
            guard await SkillInstaller.Harness.cursor.isPresent() else { return .skippedHarnessAbsent }
        }
        guard let nodePath = await BundledMCP.nodePath() else { return .skippedNoNode }
        guard let mcpPath = BundledMCP.mcpServerPath else { return .failed("bundled MCP script not found") }

        let dest = configPath
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let priorData = fm.fileExists(atPath: dest.path) ? try Data(contentsOf: dest) : nil

            if try remarcEntryMatches(priorData: priorData, nodePath: nodePath, mcpPath: mcpPath) {
                return .unchanged
            }

            let data = try mergedConfigData(priorData: priorData, nodePath: nodePath, mcpPath: mcpPath)
            try writeAtomicallyWithBackup(data, to: dest)
            debugLog("CursorMCPInstaller: installed MCP config at \(dest.path)")
            return priorData == nil || priorData?.isEmpty == true ? .installed : .updated
        } catch {
            debugLog("CursorMCPInstaller: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    public static func uninstall() throws {
        let dest = configPath
        guard let data = try? Data(contentsOf: dest), !data.isEmpty else { return }
        let updated = try removingRemarcConfigData(priorData: data)
        if updated != data {
            try writeAtomicallyWithBackup(updated, to: dest)
        }
    }

    public static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers["remarc"] != nil
    }

    public static func snippet(nodePath: String?, mcpPath: String?) -> String {
        let root: [String: Any] = [
            "mcpServers": [
                "remarc": [
                    "command": nodePath ?? nodePlaceholder,
                    "args": [mcpPath ?? mcpPlaceholder],
                ],
            ],
        ]
        let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func mergedConfigData(priorData: Data?, nodePath: String, mcpPath: String) throws -> Data {
        var root: [String: Any]
        if let priorData, !priorData.isEmpty {
            root = try parseRoot(from: priorData)
        } else {
            root = [:]
        }

        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let dict = existing as? [String: Any] else { throw InstallError.mcpServersNotObject }
            servers = dict
        } else {
            servers = [:]
        }

        servers["remarc"] = ["command": nodePath, "args": [mcpPath]]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func removingRemarcConfigData(priorData: Data) throws -> Data {
        var root = try parseRoot(from: priorData)
        guard var servers = root["mcpServers"] as? [String: Any] else {
            return priorData
        }

        servers.removeValue(forKey: "remarc")
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func parseRoot(from data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.rootNotObject
        }
        return root
    }

    private static func remarcEntryMatches(priorData: Data?, nodePath: String, mcpPath: String) throws -> Bool {
        guard let priorData, !priorData.isEmpty else { return false }
        let root = try parseRoot(from: priorData)
        guard let servers = root["mcpServers"] as? [String: Any] else { return false }
        guard let remarc = servers["remarc"] as? [String: Any] else { return false }
        return remarc["command"] as? String == nodePath
            && remarc["args"] as? [String] == [mcpPath]
    }

    private static func writeAtomicallyWithBackup(_ data: Data, to dest: URL) throws {
        let fm = FileManager.default
        let backup = dest.appendingPathExtension("backup")

        if fm.fileExists(atPath: backup.path) {
            try fm.removeItem(at: backup)
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.copyItem(at: dest, to: backup)
        }

        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            if fm.fileExists(atPath: backup.path) {
                _ = try? fm.replaceItemAt(dest, withItemAt: backup)
            }
            throw error
        }

        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
    }
}
