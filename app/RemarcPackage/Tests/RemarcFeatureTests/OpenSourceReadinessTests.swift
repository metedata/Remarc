import Foundation
import XCTest

final class OpenSourceReadinessTests: XCTestCase {
    private let fileManager = FileManager.default

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    func testPublicRepositoryContract() throws {
        let requiredPaths = [
            "LICENSE",
            "README.md",
            "CONTRIBUTING.md",
            "SECURITY.md",
            "CHANGELOG.md",
            "THIRD-PARTY-NOTICES.md",
            ".gitleaks.toml",
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml",
        ]
        for path in requiredPaths {
            XCTAssertTrue(
                fileManager.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                "Public repository is missing required path: \(path)"
            )
        }

        let forbiddenPaths = [
            ".mcp.json",
            "appcast.xml",
            "docs/internal",
            "landing-pages",
            "scripts/build-clean-mirror.sh",
            "supabase",
            "app/RemarcPackage/Sources/RemarcFeature/Services/SentryService.swift",
            "app/RemarcPackage/Sources/RemarcFeature/Services/FeedbackService.swift",
            "app/RemarcPackage/Sources/RemarcFeature/Views/FeedbackInputController.swift",
        ]
        for path in forbiddenPaths {
            XCTAssertFalse(
                fileManager.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path),
                "Private or retired path must not be published: \(path)"
            )
        }
    }

    func testShippingSourcesContainNoRetiredTelemetryOrFeedbackBackend() throws {
        let roots = [
            "app/RemarcPackage/Package.swift",
            "app/RemarcPackage/Package.resolved",
            "app/RemarcPackage/Sources",
            "app/Remarc",
            "app/Config",
        ]
        let forbiddenMarkers = [
            "sentry-cocoa",
            "SentrySDK",
            "SentryService",
            "import Sentry",
            "FeedbackService",
            "FeedbackInputController",
            "import Supabase",
            "SUPABASE_",
            "supabase.co",
        ]

        for relativeRoot in roots {
            let root = repositoryRoot.appendingPathComponent(relativeRoot)
            for file in try sourceFiles(beneath: root) {
                let content = try String(contentsOf: file, encoding: .utf8)
                for marker in forbiddenMarkers {
                    XCTAssertFalse(
                        content.contains(marker),
                        "Retired marker '\(marker)' remains in \(relativePath(for: file))"
                    )
                }
            }
        }
    }

    func testReleaseWorkflowCannotUseRetiredDistributionOrClobberAssets() throws {
        let workflowURL = repositoryRoot.appendingPathComponent(".github/workflows/release.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)

        let forbiddenMarkers = [
            "R2_ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY",
            "R2_ACCOUNT_ID",
            "wrangler r2",
            "cd mcp",
            "npm ci",
            "--clobber",
            "Sparkle-2.6.4",
        ]
        for marker in forbiddenMarkers {
            XCTAssertFalse(workflow.contains(marker), "Release workflow contains retired marker: \(marker)")
        }

        let requiredMarkers = [
            "refs/heads/main",
            "cancel-in-progress: false",
            "-onlyUsePackageVersionsFromResolvedFile",
            "Sparkle/bin/sign_update",
            "codesign --verify --deep --strict",
            "spctl --assess --type execute",
            "xcrun stapler validate",
            "Remarc.zip.sha256",
            "current-appcast.xml",
            "appcast already advertises version",
            "HEAD is not the workflow's release commit",
            "Verify published release assets",
            "Verify published appcast",
            "--draft",
            "--draft=false",
        ]
        for marker in requiredMarkers {
            XCTAssertTrue(workflow.contains(marker), "Release workflow is missing safeguard: \(marker)")
        }
    }

    private func sourceFiles(beneath root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            XCTFail("Readiness scan root is missing: \(relativePath(for: root))")
            return []
        }
        if !isDirectory.boolValue {
            return [root]
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate readiness scan root: \(relativePath(for: root))")
            return []
        }

        return try enumerator.compactMap { element in
            guard let url = element as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            let textExtensions = ["swift", "json", "plist", "xcconfig", "entitlements"]
            return values.isRegularFile == true && textExtensions.contains(url.pathExtension)
                ? url
                : nil
        }
    }

    private func relativePath(for url: URL) -> String {
        url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
    }
}
