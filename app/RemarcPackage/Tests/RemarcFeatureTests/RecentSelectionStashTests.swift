import Foundation
import Testing
@testable import RemarcFeature

@Suite("Recent selection stash")
struct RecentSelectionStashTests {
    private func makeSelection(_ text: String) -> TextSelection {
        TextSelection(
            text: text,
            source: "Notes",
            appBundleID: "com.apple.Notes",
            screenRect: CGRect(x: 10, y: 20, width: 100, height: 18)
        )
    }

    @Test("A freshly stored selection is returned within the window")
    func freshSelectionIsReturned() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 100.5, maxAge: 2.0)?.text == "hello")
    }

    @Test("A selection older than the window is not returned")
    func staleSelectionIsDropped() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 103.0, maxAge: 2.0) == nil)
    }

    @Test("An empty stash returns nothing")
    func emptyStashReturnsNothing() {
        let stash = RecentSelectionStash()
        #expect(stash.selection(at: 100.0, maxAge: 2.0) == nil)
    }

    @Test("Storing a second selection replaces the first")
    func storeReplaces() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("first"), at: 100.0)
        stash.store(makeSelection("second"), at: 101.0)
        #expect(stash.selection(at: 101.5, maxAge: 2.0)?.text == "second")
    }

    @Test("Clearing discards the stash")
    func clearDiscards() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        stash.clear()
        #expect(stash.selection(at: 100.1, maxAge: 2.0) == nil)
    }

    @Test("The stash preserves the selection rectangle")
    func rectIsPreserved() {
        var stash = RecentSelectionStash()
        stash.store(makeSelection("hello"), at: 100.0)
        #expect(stash.selection(at: 100.1, maxAge: 2.0)?.screenRect?.width == 100)
    }
}
