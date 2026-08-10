import XCTest
@testable import RemarcFeature

final class MCPManagerStatusTests: XCTestCase {
    private func plugin(installed: Bool, enabled: Bool) -> PluginInstallState {
        PluginInstallState(
            remarcInstalled: installed,
            remarcEnabled: enabled,
            remarcHooksInstalled: false,
            remarcHooksEnabled: false
        )
    }

    func testInstalledAndEnabledPluginReportsConnected() {
        XCTAssertTrue(MCPManager.resolveEnabled(
            pluginState: plugin(installed: true, enabled: true),
            legacyRegistered: false
        ))
    }

    func testInstalledButDisabledPluginIsNotConnected() {
        XCTAssertFalse(MCPManager.resolveEnabled(
            pluginState: plugin(installed: true, enabled: false),
            legacyRegistered: false
        ))
    }

    func testLegacyRegistrationAloneStillReportsConnected() {
        XCTAssertTrue(MCPManager.resolveEnabled(
            pluginState: .zero,
            legacyRegistered: true
        ))
    }

    func testNothingDetectedReportsNotConnected() {
        XCTAssertFalse(MCPManager.resolveEnabled(
            pluginState: .zero,
            legacyRegistered: false
        ))
    }
}
