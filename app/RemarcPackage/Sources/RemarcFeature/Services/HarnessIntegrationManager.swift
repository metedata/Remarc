import Combine
import Foundation

@MainActor
public final class HarnessIntegrationManager: ObservableObject {
    public static let shared = HarnessIntegrationManager()

    public struct HarnessStatus: Equatable, Sendable {
        public var skill: SkillInstaller.Result
        public var mcp: MCPState
    }

    public enum MCPState: Equatable, Sendable {
        case installed
        case notInstalled
        case skippedHarnessAbsent
        case skippedNoNode
        case failed(String)

        public var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    private enum DisabledHarnesses {
        private static let key = "mcpIntegrations.disabledHarnesses"

        static func contains(_ harness: SkillInstaller.Harness) -> Bool {
            Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(harness.storageID)
        }

        static func insert(_ harness: SkillInstaller.Harness) {
            var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            values.insert(harness.storageID)
            UserDefaults.standard.set(Array(values).sorted(), forKey: key)
        }

        static func remove(_ harness: SkillInstaller.Harness) {
            var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            values.remove(harness.storageID)
            UserDefaults.standard.set(Array(values).sorted(), forKey: key)
        }
    }

    @Published public private(set) var statuses: [SkillInstaller.Harness: HarnessStatus] = [:]
    @Published public private(set) var isWorking = false
    @Published public private(set) var workingHarnesses: Set<SkillInstaller.Harness> = []
    @Published public private(set) var lastRunDate: Date?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        MCPManager.shared.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.refreshClaudeCodeMCP(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    public func installAll(force: Bool = false) async {
        isWorking = true
        defer { isWorking = false }

        var next: [SkillInstaller.Harness: HarnessStatus] = [:]

        for harness in SkillInstaller.Harness.allCases {
            // Claude Code and Codex ship as marketplace plugins
            // (PluginInstaller / CodexPluginInstaller); only Cursor still
            // uses the app-side installer. This is the final state:
            // revision 4 cut the Cursor migration, so Cursor keeps this
            // path for good.
            if harness == .claudeCode || harness == .codex { continue }

            let harnessIsPresent: Bool
            if force {
                harnessIsPresent = true
            } else {
                harnessIsPresent = await harness.isPresent()
            }

            if !harnessIsPresent {
                next[harness] = HarnessStatus(skill: .skippedHarnessAbsent, mcp: .skippedHarnessAbsent)
            } else if !force && DisabledHarnesses.contains(harness) {
                next[harness] = HarnessStatus(skill: .notInstalled, mcp: .notInstalled)
            } else {
                if force { DisabledHarnesses.remove(harness) }
                let skill = await SkillInstaller.install(for: harness, force: force)
                let mcp = await installMCP(for: harness, force: force)
                next[harness] = HarnessStatus(skill: skill, mcp: mcp)
            }
        }

        if var claude = next[.claudeCode] {
            if claude.skill != .skippedHarnessAbsent {
                claude.mcp = DisabledHarnesses.contains(.claudeCode) ? .notInstalled : (MCPManager.shared.isEnabled ? .installed : .notInstalled)
            }
            next[.claudeCode] = claude
        }

        statuses = next
        lastRunDate = Date()
    }

    public func retry(_ harness: SkillInstaller.Harness) async {
        await install(harness, force: false)
    }

    public func forceInstall(_ harness: SkillInstaller.Harness) async {
        await install(harness, force: true)
    }

    public func enable(_ harness: SkillInstaller.Harness) async {
        await install(harness, force: harness == .claudeCode)
    }

    public func uninstall(_ harness: SkillInstaller.Harness) async {
        guard beginWork(on: harness) else { return }
        defer { endWork(on: harness) }

        DisabledHarnesses.insert(harness)
        let skill = SkillInstaller.uninstall(for: harness)
        let mcp = await uninstallMCP(for: harness)
        statuses[harness] = HarnessStatus(skill: skill, mcp: mcp)
        lastRunDate = Date()
    }

    private func install(_ harness: SkillInstaller.Harness, force: Bool) async {
        guard beginWork(on: harness) else { return }
        defer { endWork(on: harness) }

        DisabledHarnesses.remove(harness)
        let skill = await SkillInstaller.install(for: harness, force: force)
        let mcp = await installMCP(for: harness, force: force)
        statuses[harness] = HarnessStatus(skill: skill, mcp: mcp)
        lastRunDate = Date()
    }

    private func installMCP(for harness: SkillInstaller.Harness, force: Bool) async -> MCPState {
        switch harness {
        case .claudeCode:
            if force {
                return await MCPManager.shared.enable() ? .installed : .failed("Could not register MCP server")
            }
            return MCPManager.shared.isEnabled ? .installed : .notInstalled
        case .codex:
            return mapCodex(await CodexMCPInstaller.install(force: force))
        case .cursor:
            return mapCursor(await CursorMCPInstaller.install(force: force))
        }
    }

    private func uninstallMCP(for harness: SkillInstaller.Harness) async -> MCPState {
        switch harness {
        case .claudeCode:
            if !MCPManager.shared.isEnabled { return .notInstalled }
            return await MCPManager.shared.disable() ? .notInstalled : .failed("Could not unregister MCP server")
        case .codex:
            do {
                try CodexMCPInstaller.uninstall()
                return .notInstalled
            } catch {
                return .failed(error.localizedDescription)
            }
        case .cursor:
            do {
                try CursorMCPInstaller.uninstall()
                return .notInstalled
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func mapCodex(_ result: CodexMCPInstaller.Result) -> MCPState {
        switch result {
        case .installed, .updated, .unchanged:
            return .installed
        case .skippedNoNode:
            return .skippedNoNode
        case .skippedHarnessAbsent:
            return .skippedHarnessAbsent
        case .failed(let message):
            return .failed(message)
        }
    }

    private func mapCursor(_ result: CursorMCPInstaller.Result) -> MCPState {
        switch result {
        case .installed, .updated, .unchanged:
            return .installed
        case .skippedNoNode:
            return .skippedNoNode
        case .skippedHarnessAbsent:
            return .skippedHarnessAbsent
        case .failed(let message):
            return .failed(message)
        }
    }

    private func refreshClaudeCodeMCP(enabled: Bool) {
        var current = statuses[.claudeCode]
            ?? HarnessStatus(skill: .failed("not yet installed"), mcp: .notInstalled)
        current.mcp = DisabledHarnesses.contains(.claudeCode) ? .notInstalled : (enabled ? .installed : .notInstalled)
        statuses[.claudeCode] = current
    }

    private func beginWork(on harness: SkillInstaller.Harness) -> Bool {
        guard !workingHarnesses.contains(harness) else { return false }
        workingHarnesses.insert(harness)
        return true
    }

    private func endWork(on harness: SkillInstaller.Harness) {
        workingHarnesses.remove(harness)
    }
}
