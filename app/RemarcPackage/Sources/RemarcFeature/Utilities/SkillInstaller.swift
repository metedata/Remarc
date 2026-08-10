import Foundation

public enum SkillInstaller {
    public enum Harness: String, CaseIterable, Identifiable, Sendable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case cursor = "Cursor"

        public var id: String { rawValue }

        var storageID: String {
            switch self {
            case .claudeCode: return "claudeCode"
            case .codex: return "codex"
            case .cursor: return "cursor"
            }
        }

        public var rootPath: URL {
            switch self {
            case .claudeCode:
                return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            case .codex:
                return CodexLocations.home
            case .cursor:
                return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor")
            }
        }

        public var skillPath: URL {
            rootPath.appending(path: "skills/remarc/SKILL.md")
        }

        public func isPresent() async -> Bool {
            let fm = FileManager.default
            switch self {
            case .claudeCode:
                if fm.fileExists(atPath: rootPath.path) { return true }
                return await ShellResolver.resolveBinaryPath("claude") != nil
            case .codex:
                if fm.fileExists(atPath: rootPath.path) { return true }
                return await ShellResolver.resolveBinaryPath("codex") != nil
            case .cursor:
                let candidates = [
                    "/Applications/Cursor.app",
                    NSHomeDirectory() + "/Applications/Cursor.app",
                ]
                return candidates.contains { fm.fileExists(atPath: $0) }
            }
        }
    }

    public enum Result: Equatable, Sendable {
        case installed
        case updated
        case unchanged
        case notInstalled
        case skippedHarnessAbsent
        case failed(String)
    }

    public static func installForDetectedHarnesses(force: Bool = false) async -> [Harness: Result] {
        guard let source = BundledMCP.bundledSkillURL else {
            debugLog("SkillInstaller: bundled skill not found")
            return Dictionary(uniqueKeysWithValues: Harness.allCases.map {
                ($0, .failed("bundled resource missing"))
            })
        }

        var results: [Harness: Result] = [:]
        for harness in Harness.allCases {
            results[harness] = await installOne(from: source, for: harness, force: force)
        }
        return results
    }

    public static func install(for harness: Harness, force: Bool = false) async -> Result {
        guard let source = BundledMCP.bundledSkillURL else {
            debugLog("SkillInstaller: bundled skill not found")
            return .failed("bundled resource missing")
        }
        return await installOne(from: source, for: harness, force: force)
    }

    public static func uninstall(for harness: Harness) -> Result {
        let fm = FileManager.default
        let dest = harness.skillPath

        do {
            guard fm.fileExists(atPath: dest.path) else { return .notInstalled }
            try fm.removeItem(at: dest)
            debugLog("SkillInstaller: \(harness.rawValue) skill removed from \(dest.path)")
            return .notInstalled
        } catch {
            debugLog("SkillInstaller \(harness.rawValue): failed to remove skill: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    public static func bundledSkillContent() -> String? {
        guard let url = BundledMCP.bundledSkillURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func installOne(from source: URL, for harness: Harness, force: Bool) async -> Result {
        if !force {
            guard await harness.isPresent() else { return .skippedHarnessAbsent }
        }

        let fm = FileManager.default
        let dest = harness.skillPath

        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let newContent = try Data(contentsOf: source)
            let priorExisted = fm.fileExists(atPath: dest.path)
            let priorContent = priorExisted ? try? Data(contentsOf: dest) : nil

            if priorContent == newContent {
                return .unchanged
            }

            try newContent.write(to: dest, options: .atomic)
            debugLog("SkillInstaller: \(harness.rawValue) skill installed at \(dest.path)")
            return priorExisted ? .updated : .installed
        } catch {
            debugLog("SkillInstaller \(harness.rawValue): \(error)")
            return .failed(error.localizedDescription)
        }
    }
}
