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
}
