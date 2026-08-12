# OMP Settings Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OMP a first-class Remarc integration and expose shared instant-delivery controls without requiring Claude Code hooks.

**Architecture:** Add a read-only Foundation detector that evaluates each OMP agent profile independently. Preferences renders the detector result through the existing status-row vocabulary and moves shared wake controls into a stable top-level section.

**Tech Stack:** Swift 6, Foundation, SwiftUI, XCTest, macOS 14+

## Global Constraints

- Work only in `.worktrees/omp-preferences`; do not modify `main` directly.
- Do not create commits unless the user explicitly asks.
- Read only OMP configuration; never mutate it or run OMP from Preferences.
- Detect `~/.omp/agent` and `~/.omp/profiles/<name>/agent` independently.
- Do not combine MCP, skill, or extension artifacts from different profiles.
- Preserve the existing Remarc color tokens and integration-row visual vocabulary.
- Keep Claude-only session creation and conversation-clear controls under Claude Code.

---

### Task 1: OMP integration detector

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/OMPIntegrationDetector.swift`
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/OMPIntegrationDetectorTests.swift`

**Interfaces:**
- Produces: `OMPProfileState`, with `name`, `hasRemarcArtifacts`, `remarcConfigured`, `hasWakeArtifacts`, and `wakeConfigured`.
- Produces: `OMPIntegrationState`, with sorted `profiles`, `remarcProfiles`, `wakeProfiles`, `hasRemarcArtifacts`, and `hasWakeArtifacts`.
- Produces: `OMPIntegrationDetector.read(ompDirectory:fileManager:) -> OMPIntegrationState`.

- [ ] **Step 1: Write failing detector tests**

Create table-driven XCTest coverage using temporary directories. Each fixture writes only the files needed by the case. Assert these observable contracts:

```swift
func testDefaultProfileReportsCompleteMCPAndWakeInstall() throws {
    let root = try makeOMPRoot()
    try installMCP(in: root.appendingPathComponent("agent"))
    try installWake(in: root.appendingPathComponent("agent"))

    let state = OMPIntegrationDetector.read(ompDirectory: root)

    XCTAssertEqual(state.remarcProfiles, ["Default"])
    XCTAssertEqual(state.wakeProfiles, ["Default"])
}

func testNamedProfilesRemainIndependent() throws {
    let root = try makeOMPRoot()
    try installMCP(in: root.appendingPathComponent("profiles/work/agent"))
    try installWake(in: root.appendingPathComponent("profiles/personal/agent"))

    let state = OMPIntegrationDetector.read(ompDirectory: root)

    XCTAssertEqual(state.remarcProfiles, ["work"])
    XCTAssertTrue(state.wakeProfiles.isEmpty)
    XCTAssertTrue(state.hasRemarcArtifacts)
    XCTAssertTrue(state.hasWakeArtifacts)
}

func testDisabledOrMalformedMCPNeedsSetup() throws {
    let root = try makeOMPRoot()
    let agent = root.appendingPathComponent("agent")
    try writeMCP(in: agent, disabledServers: ["remarc"])
    try createDirectory(agent.appendingPathComponent("skills/remarc"))

    let disabled = OMPIntegrationDetector.read(ompDirectory: root)
    XCTAssertTrue(disabled.remarcProfiles.isEmpty)
    XCTAssertTrue(disabled.hasRemarcArtifacts)

    try Data("{".utf8).write(to: agent.appendingPathComponent("mcp.json"))
    let malformed = OMPIntegrationDetector.read(ompDirectory: root)
    XCTAssertTrue(malformed.remarcProfiles.isEmpty)
    XCTAssertTrue(malformed.hasRemarcArtifacts)
}
```

Also cover an absent `.omp` directory, multiple complete profiles sorted as `Default`, then alphabetically, `enabled: false`, a wrong `remarc` command, missing generic skill, missing review skill, and missing wake extension.

- [ ] **Step 2: Run tests and confirm RED**

Run:

```bash
swift test --filter OMPIntegrationDetectorTests
```

Expected: compilation fails because `OMPIntegrationDetector` and its state types do not exist.

- [ ] **Step 3: Implement the detector**

Use `FileManager.contentsOfDirectory` to find direct children of `profiles`. Treat the default profile as `agent`. For each profile:

```swift
public struct OMPProfileState: Equatable, Sendable {
    public let name: String
    public let hasRemarcArtifacts: Bool
    public let remarcConfigured: Bool
    public let hasWakeArtifacts: Bool
    public let wakeConfigured: Bool
}

public struct OMPIntegrationState: Equatable, Sendable {
    public let profiles: [OMPProfileState]
    public static let zero = OMPIntegrationState(profiles: [])

    public var remarcProfiles: [String] {
        profiles.filter(\.remarcConfigured).map(\.name)
    }

    public var wakeProfiles: [String] {
        profiles.filter { $0.remarcConfigured && $0.wakeConfigured }.map(\.name)
    }

    public var hasRemarcArtifacts: Bool {
        profiles.contains(where: \.hasRemarcArtifacts)
    }

    public var hasWakeArtifacts: Bool {
        profiles.contains(where: \.hasWakeArtifacts)
    }
}
```

A profile is MCP-configured only when `mcp.json` parses, `mcpServers.remarc` is enabled, `disabledServers` does not contain `remarc`, its command is non-empty, one argument ends in `remarc-mcp.js`, and `skills/remarc` resolves. A wake install is configured only when both `extensions/remarc-wake` and `skills/remarc-review` resolve. Use `fileExists(atPath:isDirectory:)` so broken symlinks do not count.

- [ ] **Step 4: Run detector tests and confirm GREEN**

Run:

```bash
swift test --filter OMPIntegrationDetectorTests
```

Expected: all detector tests pass.

---

### Task 2: First-class OMP and Instant delivery sections

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WakeReachability.swift:46-90`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift:139-181,1532-1557,1715-1927`
- Modify: `app/RemarcPackage/Tests/RemarcFeatureTests/WakeReachabilityTests.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/OMPIntegrationDetectorTests.swift`

**Interfaces:**
- Consumes: `OMPIntegrationDetector.read(ompDirectory:fileManager:) -> OMPIntegrationState`.
- Produces: `WakeReachability.anyLiveOMPPairingExists(in:now:) -> Bool`.
- Produces: an OMP section with independent `remarc` and `remarc-wake` statuses; wake reports **Active** only for a live OMP marker.
- Produces: a stable Instant delivery section using `SettingsManager.wakeOnCommentEnabled` and `wakeHooksAvailable`.

- [ ] **Step 1: Add a failing UI-state contract test**

Add computed labels to `OMPIntegrationState` so display text remains independently testable:

```swift
func testProfileSummaryUsesDefaultThenNamedProfiles() throws {
    let state = OMPIntegrationState(profiles: [
        .init(name: "work", hasRemarcArtifacts: true, remarcConfigured: true, hasWakeArtifacts: true, wakeConfigured: true),
        .init(name: "Default", hasRemarcArtifacts: true, remarcConfigured: true, hasWakeArtifacts: true, wakeConfigured: true),
    ])

    XCTAssertEqual(state.remarcProfileSummary, "Default, work")
    XCTAssertEqual(state.wakeProfileSummary, "Default, work")
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter OMPIntegrationDetectorTests/testProfileSummaryUsesDefaultThenNamedProfiles
```

Expected: compilation fails because the summary properties do not exist.

- [ ] **Step 3: Add minimal summary properties**

Return the already-sorted configured profile names joined with `", "`. Return `nil` for no configured profile so the view can omit profile copy.

- [ ] **Step 4: Add a failing live OMP status test**

Extend the existing marker fixture in `WakeReachabilityTests` with a `harness` field and assert that only a live OMP marker activates OMP status:

```swift
func testLiveOMPStatusRequiresOMPHarnessAndLiveLease() throws {
    try writeReachableMarker(harness: "claude-code", ownerPID: getpid())
    XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: markerDirectory))

    try writeReachableMarker(harness: "omp", ownerPID: getpid())
    XCTAssertTrue(WakeReachability.anyLiveOMPPairingExists(in: markerDirectory))
}
```

- [ ] **Step 5: Run the runtime-status test and confirm RED**

Run:

```bash
swift test --filter WakeReachabilityTests/testLiveOMPStatusRequiresOMPHarnessAndLiveLease
```

Expected: compilation fails because `anyLiveOMPPairingExists` does not exist.

- [ ] **Step 6: Implement live OMP marker filtering**

Add `WakeReachability.anyLiveOMPPairingExists(in:now:)`. Reuse the same JSON parsing and `isLive` lease check as the composer path, but require `harness == "omp"`, `wakeCapable == true`, and a non-empty `remarcSessionId`. Do not treat the marker as installation proof.

- [ ] **Step 7: Add OMP view state and refresh**

Add:

```swift
@State private var ompIntegrationState: OMPIntegrationState = .zero
@State private var ompIntegrationChecked = false
@State private var ompWakeActive = false
```

In the MCP tab `.task`, call the configuration detector, call `WakeReachability.anyLiveOMPPairingExists()`, and assign the three state values. Do not invoke OMP or read process output.

- [ ] **Step 8: Render OMP after Claude Code**

Insert `ompIntegrationSection` between Claude Code and Codex. Reuse `pluginRow` twice:

- `remarc`: installed when any Remarc artifacts exist, healthy when `remarcProfiles` is non-empty, status **Installed** when healthy.
- `remarc-wake`: installed when any wake artifacts exist, healthy when `wakeProfiles` is non-empty, status **Active** when healthy and `ompWakeActive`, otherwise **Installed**.
- Use the configured profile summary in each subtitle.
- When either row is unhealthy, show a SwiftUI `Link` to `https://github.com/sorcerai/Remarc/tree/main/integrations/omp#readme` titled **Open OMP setup instructions**. Do not show repo-relative shell commands and do not add an in-app installer.

Add an optional installed-status label to `pluginRowStatus` and `pluginRow`, defaulting to `Installed`, so existing integrations remain unchanged.

- [ ] **Step 9: Split shared wake controls from Claude controls**

Keep these in `hooksSettingsRows`:

- Auto-create session for new conversations.
- When a conversation is cleared.
- Claude-specific lifecycle help.

Move the wake toggle and availability help into `instantDeliverySection`, rendered after OMP regardless of Claude plugin state. Use this copy:

```text
Allow comments to wake paired agent sessions
Adds Send Instantly beside Save for Remarc sessions paired with a running Claude Code or OMP agent.
Send Instantly appears only when the selected Remarc session has a live pairing.
```

Remove claims that Codex and all non-Claude sessions cannot be woken. Codex remains unsupported, but the positive live-pairing rule is sufficient and will not become stale when another harness gains support.

- [ ] **Step 10: Run focused tests and inspect compiler diagnostics**

Run:

```bash
swift test --filter 'OMPIntegrationDetectorTests|WakeReachabilityTests'
```

Expected: detector, display-state, and live-marker tests pass with no new warnings.

---

### Task 3: Release verification

**Files:**
- Verify: all changed files above.
- Update only if required by observed behavior: `integrations/omp/README.md`.

**Interfaces:**
- Consumes: completed detector and settings UI.
- Produces: a running Remarc build that visibly reports OMP status and exposes Instant delivery.

- [ ] **Step 1: Run the complete Swift suite serially**

Run:

```bash
swift test --parallel --num-workers 1
```

Expected: all tests pass. Serial execution avoids the repository’s known shared-resource test interference.

- [ ] **Step 2: Run the OMP installer and wake protocol gate**

Run from the worktree root:

```bash
bash integrations/omp/test-install.sh
```

Expected: installer tests and wake protocol tests pass.

- [ ] **Step 3: Build the unsigned app**

Run from `app/`:

```bash
xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Relaunch the exact worktree build**

Run from `app/`:

```bash
pkill -x Remarc; sleep 0.5; open "$(pwd)/DerivedData/Build/Products/Debug/Remarc.app"
```

Expected: Remarc launches from the worktree DerivedData path.

- [ ] **Step 5: Inspect the rendered settings**

Open Preferences → MCP Integrations and verify:

- OMP appears between Claude Code and Codex.
- `remarc` and `remarc-wake` report Installed for the configured profile.
- Instant delivery is visible without Claude `remarc-hooks`.
- Enabling the toggle makes the Send Instantly button appear in a new composer targeting the paired `test1` session.
- The generic Other MCP clients section remains available.

- [ ] **Step 6: Review the uncommitted diff**

Run the project’s code-review workflow against the complete diff. Leave all files uncommitted for user review.
