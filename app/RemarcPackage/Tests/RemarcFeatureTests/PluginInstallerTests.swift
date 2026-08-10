import XCTest
@testable import RemarcFeature

final class PluginInstallerTests: XCTestCase {
    private func result(_ exitCode: Int32, _ output: String = "", timedOut: Bool = false) -> ProcessRunner.CommandResult {
        ProcessRunner.CommandResult(exitCode: exitCode, output: output, timedOut: timedOut)
    }

    func testInstallSuccessWinsEvenWhenMarketplaceAddFailed() {
        // `marketplace add` fails whenever the marketplace is already
        // registered - that must not fail the overall install.
        let outcome = PluginInstaller.outcome(
            install: result(0, "Installed remarc@remarc"),
            marketplace: result(1, "Error: marketplace 'remarc' already exists")
        )
        XCTAssertEqual(outcome, .success)
    }

    func testInstallFailureSurfacesInstallOutput() {
        let outcome = PluginInstaller.outcome(
            install: result(1, "Error: plugin not found in marketplace"),
            marketplace: result(0, "")
        )
        XCTAssertEqual(outcome, .failed("Error: plugin not found in marketplace"))
    }

    func testInstallFailureWithSilentInstallFallsBackToMarketplaceOutput() {
        // Shared root cause (e.g. no network during the marketplace clone):
        // install exits nonzero with nothing useful, marketplace add named it.
        let outcome = PluginInstaller.outcome(
            install: result(1, "  \n"),
            marketplace: result(128, "fatal: unable to access 'https://github.com/...': Could not resolve host")
        )
        XCTAssertEqual(outcome, .failed("fatal: unable to access 'https://github.com/...': Could not resolve host"))
    }

    func testInstallFailureWithNoOutputAnywhereUsesGenericMessage() {
        let outcome = PluginInstaller.outcome(
            install: result(1, ""),
            marketplace: result(0, "ok")
        )
        XCTAssertEqual(outcome, .failed("Install failed. Run the commands manually."))
    }

    func testTimeoutProducesTimeoutMessage() {
        let outcome = PluginInstaller.outcome(
            install: result(15, "", timedOut: true),
            marketplace: result(0, "")
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Timed out"))
    }

    func testUnlaunchableInstallProducesFailure() {
        let outcome = PluginInstaller.outcome(install: nil, marketplace: nil)
        guard case .failed = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
    }

    func testTimedOutRunWithExitZeroIsNotSuccess() {
        // A wrapper that traps SIGTERM and exits 0 must still read as a
        // timeout, never as a completed install.
        let outcome = PluginInstaller.outcome(
            install: result(0, "", timedOut: true),
            marketplace: result(0, "")
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Timed out"))
    }

    // MARK: - Marketplace provenance (a look-alike marketplace named remarc
    // must never satisfy the install path)

    private let realMarketplaceList = """
    [ { "name": "claude-plugins-official", "source": "github", "repo": "anthropics/claude-plugins-official", "installLocation": "/x/official" },
      { "name": "remarc", "source": "github", "repo": "metedata/remarc-agent-plugins", "installLocation": "/x/remarc" } ]
    """.data(using: .utf8)!

    func testProvenanceOursWhenRepoMatches() {
        XCTAssertEqual(PluginInstaller.marketplaceProvenance(listJSON: realMarketplaceList), .ours)
    }

    func testProvenanceForeignWhenRepoDiffers() {
        let json = """
        [ { "name": "remarc", "source": "github", "repo": "attacker/remarc-lookalike", "installLocation": "/x/evil" } ]
        """.data(using: .utf8)!
        XCTAssertEqual(PluginInstaller.marketplaceProvenance(listJSON: json), .foreign("attacker/remarc-lookalike"))
    }

    func testProvenanceForeignForLocalSourceWithoutRepo() {
        let json = """
        [ { "name": "remarc", "source": "local", "installLocation": "/tmp/somewhere" } ]
        """.data(using: .utf8)!
        XCTAssertEqual(PluginInstaller.marketplaceProvenance(listJSON: json), .foreign("/tmp/somewhere"))
    }

    func testProvenanceAbsentWhenMissingOrMalformed() {
        XCTAssertEqual(PluginInstaller.marketplaceProvenance(listJSON: "[]".data(using: .utf8)!), .absent)
        XCTAssertEqual(PluginInstaller.marketplaceProvenance(listJSON: "nope".data(using: .utf8)!), .absent)
    }

    func testLongErrorOutputIsTruncated() {
        let outcome = PluginInstaller.outcome(
            install: result(1, String(repeating: "x", count: 1000)),
            marketplace: nil
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertEqual(message.count, 300)
    }

    func testCommandConstruction() {
        XCTAssertEqual(
            PluginInstaller.marketplaceArguments,
            ["plugin", "marketplace", "add", "metedata/remarc-agent-plugins"]
        )
        XCTAssertEqual(
            PluginInstaller.installArguments(plugin: "remarc-hooks"),
            ["plugin", "install", "remarc-hooks@remarc"]
        )
        let manual = PluginInstaller.manualCommands(plugin: "remarc")
        XCTAssertTrue(manual.contains("claude plugin marketplace add metedata/remarc-agent-plugins"))
        XCTAssertTrue(manual.contains("claude plugin install remarc@remarc"))
    }

    func testRunCollectingResultCapturesStderrAndNonzeroExit() async throws {
        // Real process round-trip: stderr is merged and nonzero exit still
        // returns a result (unlike runCapture, which returns nil).
        let result = await ProcessRunner.runCollectingResult(
            "/bin/sh",
            arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
            timeoutSeconds: 5
        )
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.exitCode, 3)
        XCTAssertFalse(unwrapped.timedOut)
        XCTAssertTrue(unwrapped.output.contains("out"))
        XCTAssertTrue(unwrapped.output.contains("err"))
    }

    func testRunCollectingResultFlagsTimeout() async throws {
        let result = await ProcessRunner.runCollectingResult(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeoutSeconds: 0.2
        )
        let unwrapped = try XCTUnwrap(result)
        XCTAssertTrue(unwrapped.timedOut)
        XCTAssertNotEqual(unwrapped.exitCode, 0)
    }
}
