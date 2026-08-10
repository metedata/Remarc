import Testing
import Foundation
@testable import RemarcFeature

@Suite("Compact timestamp formatting")
@MainActor
struct CompactTimestampTests {
    /// Arbitrary fixed reference instant. All cases position `createdAt` relative to this.
    private let now = Date(timeIntervalSince1970: 1_778_800_000)

    @Test("under 24h old, 24-hour mode: a colon time, no date separator, no meridiem")
    func recentTwentyFourHour() {
        let created = now.addingTimeInterval(-60 * 60) // 1h before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(result.contains(":"))
        #expect(!result.contains("-"))            // not the .iso date tier (yyyy-MM-dd)
        #expect(!result.contains("AM") && !result.contains("PM"))
    }

    @Test("under 24h old, 12-hour mode: includes a meridiem")
    func recentTwelveHour() {
        let created = now.addingTimeInterval(-60 * 60)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: false, now: now)
        #expect(result.contains(":"))
        #expect(result.contains("AM") || result.contains("PM"))
    }

    @Test("exactly 24h old falls into the date tier")
    func exactlyTwentyFourHours() {
        let created = now.addingTimeInterval(-24 * 60 * 60)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(result.contains("-"))             // .iso date tier: yyyy-MM-dd
    }

    @Test("just under 24h old stays in the time tier")
    func justUnderTwentyFourHours() {
        let created = now.addingTimeInterval(-(24 * 60 * 60 - 60)) // 23h59m before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(!result.contains("-"))
    }

    @Test("older than 24h is formatted with the supplied exportDateFormat")
    func olderUsesDateFormat() {
        let created = now.addingTimeInterval(-48 * 60 * 60) // 2 days before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        // .iso produces yyyy-MM-dd: exactly two dashes, only digits and dashes.
        #expect(result.filter { $0 == "-" }.count == 2)
        #expect(result.allSatisfy { $0.isNumber || $0 == "-" })
        // The dateFormat parameter must actually be routed through to the
        // formatter: a different format must produce a different string.
        let european = created.remarcCompactTimestamp(dateFormat: .european, use24Hour: true, now: now)
        #expect(result != european)
    }

    @Test("the tier flips as `now` crosses the 24h boundary for a fixed createdAt")
    func boundaryCrossing() {
        let created = now
        let before = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true, now: created.addingTimeInterval(23 * 60 * 60))
        let after = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true, now: created.addingTimeInterval(25 * 60 * 60))
        #expect(!before.contains("-"))            // time tier
        #expect(after.contains("-"))              // date tier
        #expect(before != after)
    }
}
