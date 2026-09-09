import Foundation
import XCTest
@testable import RemarcFeature

final class ScriptInstallerTests: XCTestCase {
    func testWorktreeBuildSelectsItsOwnServerInsteadOfEnclosingCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemarcScriptTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent(".worktrees/screenshot-storage")
        let relativePath = "mcp/vendor/remarc-mcp.js"
        for (checkout, content) in [(root, "old server"), (worktree, "candidate server")] {
            let file = checkout.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        let bundle = worktree.appendingPathComponent("app/DerivedData/Build/Products/Debug/Remarc.app")
        XCTAssertEqual(ScriptInstaller.sourceTreePath(relativePath, bundleURL: bundle),
                       worktree.appendingPathComponent(relativePath).path)
    }

    func testInstalledAppWithoutSourceTreeFallsBackToBundleResolution() {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemarcScriptTests-\(UUID())/Applications/Remarc.app")
        XCTAssertNil(ScriptInstaller.sourceTreePath("mcp/vendor/\(UUID()).js", bundleURL: bundle))
    }
}
