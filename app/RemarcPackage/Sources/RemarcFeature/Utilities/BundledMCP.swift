import Foundation

enum BundledMCP {
    static func nodePath() async -> String? {
        await ShellResolver.resolveBinaryPath("node")
    }

    static var mcpServerPath: String? {
        ScriptInstaller.resolvedPath(source: "mcp/vendor/remarc-mcp.js", bundleName: "remarc-mcp", bundleExt: "js")
    }

    static var bundledSkillURL: URL? {
        Bundle.main.url(forResource: "remarc-skill", withExtension: "md")
    }
}
