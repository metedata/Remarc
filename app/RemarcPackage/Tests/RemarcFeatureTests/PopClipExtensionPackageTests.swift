import Foundation
import Testing
@testable import RemarcFeature

@Suite("PopClip extension package")
struct PopClipExtensionPackageTests {
    /// Walks up from this test file to the repo root, so the suite does not
    /// depend on the working directory the test runner happens to use.
    private static func repoRoot(from file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) {
                return url
            }
        }
        fatalError("Could not locate repo root from \(file)")
    }

    private static var config: String {
        let path = repoRoot()
            .appendingPathComponent("popclip/Remarc.popclipext/Config.ts")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static var readme: String {
        let path = repoRoot()
            .appendingPathComponent("popclip/Remarc.popclipext/readme.md")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static var directoryConfig: String {
        let path = repoRoot().appendingPathComponent("popclip-directory.yaml")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static var xcodeProject: String {
        let path = repoRoot().appendingPathComponent("app/Remarc.xcodeproj/project.pbxproj")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static var packageFiles: [URL] {
        let package = repoRoot().appendingPathComponent("popclip/Remarc.popclipext")
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: package,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                return nil
            }
            return url
        }
    }

    @Test("Config declares the Remarc identifier")
    func declaresIdentifier() {
        #expect(Self.config.contains("identifier: com.metepolat.remarc.popclip"))
    }

    @Test("Config does not claim a reserved Pilotmoon identifier prefix")
    func avoidsReservedPrefix() {
        #expect(!Self.config.contains("com.pilotmoon.popclip.extension"))
    }

    @Test("Config declares a popclipVersion new enough for module extensions")
    func declaresModuleCapableVersion() {
        #expect(Self.config.contains("popclipVersion: 4586"))
    }

    @Test("Config declares Remarc's supported macOS version")
    func declaresSupportedMacOSVersion() {
        #expect(Self.config.contains("macosVersion: \"14.0\""))
    }

    @Test("Config uses the documented target-app bundle identifier array")
    func declaresTargetAppBundleIdentifiers() {
        #expect(Self.config.contains("bundleIdentifiers: [\"com.metepolat.Remarc\"]"))
        #expect(!Self.config.contains("bundleIdentifier: com.metepolat.Remarc"))
        #expect(Self.config.contains("checkInstalled: true"))
    }

    /// Checks the declaration, not the word. A substring search for "entitlements"
    /// would fail on a code comment that merely mentions them.
    @Test("Config declares no entitlements, which is what avoids the unsigned warning")
    func declaresNoEntitlements() {
        let declarations = Self.config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("entitlements") || $0.hasPrefix("// entitlements") }
        #expect(declarations.isEmpty)
    }

    @Test("The action targets the remarc://comment host")
    func targetsCommentHost() {
        #expect(Self.config.contains("remarc://comment"))
    }

    @Test("The action never sends selection text")
    func sendsNoSelectionText() {
        #expect(!Self.config.contains("input.text"))
        #expect(!Self.config.contains("input.markdown"))
    }

    @Test("The icon referenced by the config exists in the package")
    func iconExists() {
        let icon = Self.repoRoot()
            .appendingPathComponent("popclip/Remarc.popclipext/remarc-logo.svg")
        #expect(FileManager.default.fileExists(atPath: icon.path))
    }

    /// Pins the exact icon spec, `file:` prefix included. This was a real
    /// shipped bug: `scale=80 remarc-logo.svg` (no prefix) renders a warning
    /// triangle in PopClip's bar instead of the logo. PopClip only treats a
    /// bare filename as a resource icon when the whole field is just the
    /// filename; once a modifier like `scale=80` precedes it, PopClip parses
    /// the trailing token as an icon spec, and a bare filename is not a valid
    /// spec there - it needs the `file:` prefix. Do not "simplify" this back
    /// to a bare filename.
    @Test("Config's icon spec keeps the file: prefix required alongside a modifier")
    func iconSpecKeepsFilePrefix() {
        #expect(Self.config.contains("icon: scale=80 file:remarc-logo.svg"))
    }

    @Test("Directory config opts in only the Remarc package")
    func directoryConfigTargetsRemarc() {
        #expect(Self.directoryConfig.contains("include: \"popclip/Remarc.popclipext\""))
        #expect(Self.directoryConfig.contains("versionPrefix: popclip-v"))
    }

    @Test("Directory readme covers setup, privacy, and changes")
    func directoryReadmeIsHelpful() {
        #expect(Self.readme.contains("## Use"))
        #expect(Self.readme.contains("## Privacy"))
        #expect(Self.readme.contains("never transmits the selected text"))
        #expect(Self.readme.contains("## Changelog"))
    }

    @Test("App build tracks the directory readme as an extension resource")
    func appBuildTracksDirectoryReadme() {
        #expect(Self.xcodeProject.contains("$(SRCROOT)/../popclip/Remarc.popclipext/readme.md"))
        #expect(Self.xcodeProject.contains(
            "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Remarc.popclipext/readme.md"
        ))
    }

    @Test("Directory package stays within submission limits")
    func directoryPackageStaysWithinLimits() {
        let sizes = Self.packageFiles.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        #expect(!sizes.isEmpty)
        #expect(sizes.count <= 100)
        #expect(sizes.allSatisfy { $0 <= 1_048_576 })
        #expect(sizes.reduce(0, +) <= 2_097_152)
    }
}
