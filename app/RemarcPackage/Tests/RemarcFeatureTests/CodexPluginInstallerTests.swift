import XCTest
@testable import RemarcFeature

final class CodexPluginInstallerTests: XCTestCase {
    private func result(_ exitCode: Int32, _ output: String = "", timedOut: Bool = false) -> ProcessRunner.CommandResult {
        ProcessRunner.CommandResult(exitCode: exitCode, output: output, timedOut: timedOut)
    }

    func testInstallSuccessWinsEvenWhenMarketplaceAddFailed() {
        // codex marketplace re-add exits 0 with alreadyAdded, but tolerate
        // nonzero too (older CLIs, transient states) when install succeeds.
        let outcome = CodexPluginInstaller.outcome(
            install: result(0, #"{"pluginId":"remarc@remarc"}"#),
            marketplace: result(1, "error: marketplace exists")
        )
        XCTAssertEqual(outcome, .success)
    }

    func testInstallFailureSurfacesInstallOutput() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(1, "error: plugin not found in marketplace"),
            marketplace: result(0, "")
        )
        XCTAssertEqual(outcome, .failed("error: plugin not found in marketplace"))
    }

    func testSilentInstallFailureFallsBackToMarketplaceOutput() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(1, " \n"),
            marketplace: result(128, "fatal: unable to access repo")
        )
        XCTAssertEqual(outcome, .failed("fatal: unable to access repo"))
    }

    func testTimeoutProducesTimeoutMessage() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(15, "", timedOut: true),
            marketplace: result(0, "")
        )
        guard case .failed(let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Timed out"))
    }

    func testCommandConstruction() {
        XCTAssertEqual(CodexPluginInstaller.marketplaceArguments, ["plugin", "marketplace", "add", "metedata/remarc-agent-plugins"])
        XCTAssertEqual(CodexPluginInstaller.installArguments, ["plugin", "add", "remarc@remarc"])
        let manual = CodexPluginInstaller.manualCommands()
        XCTAssertTrue(manual.contains("codex plugin marketplace add metedata/remarc-agent-plugins"))
        XCTAssertTrue(manual.contains("codex plugin marketplace upgrade remarc"))
        XCTAssertTrue(manual.contains("codex plugin add remarc@remarc"))
        // Must never tell the user to remove the plugin: reinstall-over
        // works, and removal opens a window where they have neither.
        XCTAssertFalse(manual.contains("plugin remove"))
    }

    // MARK: - Marketplace provenance (envelope verified live, codex-cli 0.146.1)

    private func provenanceJSON(_ marketplaceEntry: String) -> Data {
        #"{"marketplaces":[\#(marketplaceEntry)]}"#.data(using: .utf8)!
    }

    func testProvenanceOursForEveryCanonicalGitSource() {
        for source in [
            "metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins.git",
        ] {
            let json = provenanceJSON(#"{"name":"remarc","root":"/Users/x/.codex/.tmp/marketplaces/remarc","marketplaceSource":{"sourceType":"git","source":"\#(source)"}}"#)
            XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: json), .ours, "source: \(source)")
        }
    }

    func testProvenanceForeignForLookAlikeGitSources() {
        // Exactly what substring matching would wrongly accept.
        for source in [
            "https://github.com/evil/metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins-evil",
            "git@github.com:metedata/remarc-agent-plugins.git",
        ] {
            let json = provenanceJSON(#"{"name":"remarc","marketplaceSource":{"sourceType":"git","source":"\#(source)"}}"#)
            guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
                return XCTFail("expected foreign for \(source)")
            }
        }
    }

    func testProvenanceForeignForLocalSourceEchoingOurSlug() {
        let json = provenanceJSON(#"{"name":"remarc","marketplaceSource":{"sourceType":"local","source":"/tmp/metedata/remarc-agent-plugins"}}"#)
        guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
            return XCTFail("expected foreign for a local-source marketplace")
        }
    }

    func testProvenanceForeignWhenMarketplaceSourceMissing() {
        // Seen live: one built-in marketplace entry carries NO
        // marketplaceSource object at all. A remarc entry shaped like that
        // is foreign (never ours), not a parse error.
        let json = provenanceJSON(#"{"name":"remarc","root":"/Users/x/.codex/builtin/remarc"}"#)
        guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
            return XCTFail("expected foreign when marketplaceSource is absent")
        }
    }

    func testProvenanceAbsentWhenNoRemarcEntry() {
        let json = provenanceJSON(#"{"name":"openai-bundled","root":"/b","marketplaceSource":{"sourceType":"local","source":"/b"}}"#)
        XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: json), .absent)
    }

    func testProvenanceAbsentOnMalformedJSON() {
        XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: Data("nope".utf8)), .absent)
    }

    // MARK: - Reorder guard (pre-add / post-add provenance decisions)

    func testPreAddOutcomeLetsAbsentAndOursThrough() {
        // `.absent` before the add is the normal first-run case - no
        // marketplace exists yet, so it must fall through to the add rather
        // than being treated as a failure.
        XCTAssertNil(CodexPluginInstaller.preAddOutcome(provenance: .absent))
        XCTAssertNil(CodexPluginInstaller.preAddOutcome(provenance: .ours))
    }

    func testPreAddOutcomeBailsOnForeignBeforeTheAddCanOverwriteIt() {
        guard case .failed(let message)? = CodexPluginInstaller.preAddOutcome(provenance: .foreign("evil-source")) else {
            return XCTFail("expected a failure outcome")
        }
        XCTAssertTrue(message.contains("evil-source"))
        XCTAssertTrue(message.contains("marketplace remove remarc"))
    }

    func testPostAddOutcomeRequiresOurs() {
        XCTAssertNil(CodexPluginInstaller.postAddOutcome(provenance: .ours))
    }

    func testPostAddOutcomeFailsWhenStillAbsentAfterTheAdd() {
        // Unlike the pre-add check, `.absent` here means the add itself
        // silently failed to produce a marketplace - this must fail, not
        // fall through.
        guard case .failed(let message)? = CodexPluginInstaller.postAddOutcome(provenance: .absent) else {
            return XCTFail("expected a failure outcome")
        }
        XCTAssertTrue(message.contains("could not be added"))
    }

    func testPostAddOutcomeFailsOnForeignAfterTheAdd() {
        // Covers the TOCTOU case: something replaced the marketplace between
        // the pre-add and post-add checks.
        guard case .failed(let message)? = CodexPluginInstaller.postAddOutcome(provenance: .foreign("evil-source")) else {
            return XCTFail("expected a failure outcome")
        }
        XCTAssertTrue(message.contains("evil-source"))
    }

    // MARK: - Semver gate

    func testSemverGateAcceptsRealVersions() {
        for v in ["0.5.0", "26.721.81911", "1.0", "1.2.3-beta.1"] {
            XCTAssertTrue(CodexPluginInstaller.isNumericVersion(v), v)
        }
    }

    func testSemverGateRejectsLocalAndMalformed() {
        for v in ["local", "", "latest", "v1.2.3", "1.", ".1", "1.x"] {
            XCTAssertFalse(CodexPluginInstaller.isNumericVersion(v), v)
        }
    }
}
