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

    // MARK: - Menu bar indicator

    func testCountStyleDisappearsAtZeroOnlyWhenHidingIsOn() {
        let style = SettingsManager.MenuBarIndicatorStyle.count

        XCTAssertEqual(style.indicator(forCommentCount: 0, hidesCountAtZero: true), .none)
        XCTAssertEqual(style.indicator(forCommentCount: 0, hidesCountAtZero: false), .count(0))

        // Above zero the sub-setting is irrelevant.
        XCTAssertEqual(style.indicator(forCommentCount: 1, hidesCountAtZero: true), .count(1))
        XCTAssertEqual(style.indicator(forCommentCount: 1, hidesCountAtZero: false), .count(1))
        XCTAssertEqual(style.indicator(forCommentCount: 42, hidesCountAtZero: true), .count(42))
    }

    func testDotStyleIsBinaryAndIgnoresTheZeroSubSetting() {
        let style = SettingsManager.MenuBarIndicatorStyle.dot

        for hidesCountAtZero in [true, false] {
            XCTAssertEqual(style.indicator(forCommentCount: 0, hidesCountAtZero: hidesCountAtZero), .none)
            XCTAssertEqual(style.indicator(forCommentCount: 1, hidesCountAtZero: hidesCountAtZero), .dot)
            XCTAssertEqual(style.indicator(forCommentCount: 42, hidesCountAtZero: hidesCountAtZero), .dot)
        }
    }

    func testOffStyleNeverDrawsAnything() {
        let style = SettingsManager.MenuBarIndicatorStyle.off

        for hidesCountAtZero in [true, false] {
            for count in [0, 1, 42] {
                XCTAssertEqual(style.indicator(forCommentCount: count, hidesCountAtZero: hidesCountAtZero), .none)
            }
        }
    }

    func testMenuBarIndicatorDefaultsToTheHistoricalCountBadge() {
        let suiteName = "remarc.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No stored value: existing installs must keep the badge they have today,
        // which is a count that disappears at zero. Note that the hide-at-zero
        // default is true, so it cannot be read straight off `defaults.bool`.
        XCTAssertNil(defaults.string(forKey: "menuBarIndicatorStyle"))
        XCTAssertNil(defaults.object(forKey: "hidesMenuBarCountAtZero"))

        let style = defaults.string(forKey: "menuBarIndicatorStyle")
            .flatMap(SettingsManager.MenuBarIndicatorStyle.init(rawValue:)) ?? .count
        let hidesAtZero = defaults.object(forKey: "hidesMenuBarCountAtZero") != nil
            ? defaults.bool(forKey: "hidesMenuBarCountAtZero")
            : true

        XCTAssertEqual(style, .count)
        XCTAssertTrue(hidesAtZero)
        XCTAssertEqual(style.indicator(forCommentCount: 0, hidesCountAtZero: hidesAtZero), .none)
        XCTAssertEqual(style.indicator(forCommentCount: 3, hidesCountAtZero: hidesAtZero), .count(3))
    }
}
