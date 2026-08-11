import XCTest
@testable import RemarcFeature

@MainActor
final class SettingsManagerTests: XCTestCase {
    func testStandaloneDictationDefaultsOffAndPreservesSavedChoice() {
        let suiteName = "remarc.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SettingsManager.isDictationEnabled(in: defaults))

        defaults.set(true, forKey: SettingsManager.dictationEnabledKey)
        XCTAssertTrue(SettingsManager.isDictationEnabled(in: defaults))

        defaults.set(false, forKey: SettingsManager.dictationEnabledKey)
        XCTAssertFalse(SettingsManager.isDictationEnabled(in: defaults))
    }
}
