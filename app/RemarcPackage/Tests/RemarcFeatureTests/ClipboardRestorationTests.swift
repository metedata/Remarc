import AppKit
import Testing
@testable import RemarcFeature

@Suite("Clipboard borrowing and restoration")
@MainActor
struct ClipboardRestorationTests {
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func withPasteboard(_ test: (NSPasteboard) throws -> Void) rethrows {
        // Never exercise these cases against the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try test(pasteboard)
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @Test("Ordinary restoration preserves text, suppresses history, and adds no secret marker")
    func ordinaryRestoration() throws {
        try withPasteboard { pasteboard in
            copy("Original address", to: pasteboard)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            #expect(restoration.isCurrent)
            #expect(pasteboard.types?.contains(ClipboardRestoration.transientType) == true)
            #expect(pasteboard.types?.contains(concealed) == false)
            #expect(restoration.restore())
            #expect(pasteboard.string(forType: .string) == "Original address")
            #expect(pasteboard.types?.contains(ClipboardRestoration.transientType) == true)
            #expect(pasteboard.types?.contains(concealed) == false)
        }
    }

    @Test("Confidentiality supplied by the original app survives with its payload")
    func originalConfidentialityIsPreserved() throws {
        try withPasteboard { pasteboard in
            copy("Fictional QA secret", to: pasteboard)
            let marker = Data([1, 2, 3])
            pasteboard.setData(marker, forType: concealed)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            #expect(restoration.restore())
            #expect(pasteboard.string(forType: .string) == "Fictional QA secret")
            #expect(pasteboard.data(forType: concealed) == marker)
        }
    }

    @Test("All items and representations survive: rich text, HTML, image, file URL, and custom data")
    func allRepresentationsSurvive() throws {
        try withPasteboard { pasteboard in
            let originals: [[NSPasteboard.PasteboardType: Data]] = [
                [.string: Data("Café 🧪\nSecond line".utf8), .rtf: Data("{\\rtf1 rich}".utf8),
                 .html: Data("<b>rich</b>".utf8), concealed: Data([9])],
                [.png: Data([137, 80, 78, 71, 0, 1]), .fileURL: Data("file:///tmp/QA%20image.png".utf8),
                 NSPasteboard.PasteboardType("com.remarc.qa.custom"): Data([0, 255, 42])]
            ]
            let items = originals.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            #expect(pasteboard.writeObjects(items))
            // AppKit can advertise additional converted formats (for example
            // UTF-16). Preserve the actual clipboard, including those formats.
            let originalTypes = try #require(pasteboard.pasteboardItems).map { Set($0.types) }
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            #expect(restoration.restore())
            let restored = try #require(pasteboard.pasteboardItems)
            #expect(restored.count == 2)
            for (index, pair) in zip(restored, originals).enumerated() {
                let (item, original) = pair
                for (type, data) in original { #expect(item.data(forType: type) == data) }
                #expect(Set(item.types) == originalTypes[index].union([ClipboardRestoration.transientType]))
            }
        }
    }

    @Test("Existing transient marker data is preserved")
    func originalTransientPayloadSurvives() throws {
        try withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            pasteboard.setData(Data([7]), forType: ClipboardRestoration.transientType)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard))
            #expect(restoration.restore())
            #expect(pasteboard.data(forType: ClipboardRestoration.transientType) == Data([7]))
        }
    }

    @Test("An originally empty clipboard restores to no user data")
    func emptyClipboard() throws {
        try withPasteboard { pasteboard in
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            #expect(restoration.restore())
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(pasteboard.types == [ClipboardRestoration.transientType])
        }
    }

    @Test("New copies win, including an intentional copy of identical text", arguments: ["New address", "Temporary"])
    func newerCopyWins(newText: String) throws {
        try withPasteboard { pasteboard in
            copy("Old address", to: pasteboard)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            copy(newText, to: pasteboard)
            let newerCount = pasteboard.changeCount
            #expect(!restoration.isCurrent)
            #expect(!restoration.restore())
            #expect(pasteboard.changeCount == newerCount)
            #expect(pasteboard.string(forType: .string) == newText)
            #expect(pasteboard.types?.contains(ClipboardRestoration.transientType) == false)
        }
    }

    @Test("New non-text copies are not cleared by a delayed restore")
    func newerImageWins() throws {
        try withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            pasteboard.clearContents()
            pasteboard.setData(Data([1, 2, 3]), forType: .png)
            let count = pasteboard.changeCount
            #expect(!restoration.restore())
            #expect(pasteboard.changeCount == count)
            #expect(pasteboard.data(forType: .png) == Data([1, 2, 3]))
        }
    }

    @Test("An older operation cannot restore over a newer operation")
    func overlappingOperations() throws {
        try withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let first = try #require(ClipboardRestoration.begin(on: pasteboard, text: "First"))
            let second = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Second"))
            #expect(!first.restore())
            #expect(second.isCurrent)
            #expect(pasteboard.string(forType: .string) == "Second")
        }
    }

    @Test("Repeating a restore performs no additional clipboard write")
    func repeatedRestoreIsHarmless() throws {
        try withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let restoration = try #require(ClipboardRestoration.begin(on: pasteboard, text: "Temporary"))
            #expect(restoration.restore())
            let count = pasteboard.changeCount
            #expect(!restoration.restore())
            #expect(pasteboard.changeCount == count)
        }
    }

    @Test("Selection reading restores after copy arrival and settling", arguments: [1, 10, 49, 50, 75, 150])
    func selectionCopyArrival(arrivalPoll: Int) {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: {
                poll += 1
                if poll == arrivalPoll { copy("Selected text", to: pasteboard) }
            })
            #expect(result == "Selected text")
            #expect(poll == arrivalPoll + 30)
            #expect(pasteboard.string(forType: .string) == "Original")
            #expect(pasteboard.types?.contains(concealed) == false)
        }
    }

    @Test("The preparation write is not mistaken for a successful copy")
    func failedCopyRestoresOriginal() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: { poll += 1 })
            #expect(result == nil)
            #expect(poll == 200)
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("An immediate copy is detected even before the first poll")
    func synchronousCopy() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {
                copy("Selected", to: pasteboard)
            }, waitForNextPoll: {})
            #expect(result == "Selected")
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("A real Copy between polls preserves the latest, even when the text matches", arguments: ["Selected", "New copy"])
    func interveningCopyBeforeFirstPoll(newText: String) {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var interrupted = false
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {
                copy("Selected", to: pasteboard)
                copy(newText, to: pasteboard)
                interrupted = true
            }, isInterrupted: { interrupted }, waitForNextPoll: {})
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == newText)
            #expect(pasteboard.types?.contains(ClipboardRestoration.transientType) == false)
        }
    }

    @Test("Another owner while text is pending cancels restoration")
    func interveningCopyAfterObservation() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, isInterrupted: { poll >= 2 }, waitForNextPoll: {
                poll += 1
                if poll == 1 { pasteboard.clearContents() }
                if poll == 2 { copy("User copy", to: pasteboard) }
            })
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "User copy")
        }
    }

    @Test("A slow staged copy is read without assuming one change-count increment")
    func stagedCopy() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: {
                poll += 1
                // Model the live Figma trace: a late first write, followed by
                // several ownership changes while publishing the same text.
                if [60, 62, 86].contains(poll) { copy("Selected", to: pasteboard) }
            })
            #expect(result == "Selected")
            #expect(pasteboard.string(forType: .string) == "Original")
            #expect(poll == 116)
        }
    }

    @Test("Different content during settling is kept without requiring a key event")
    func unrelatedWriterDuringSettling() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: {
                poll += 1
                if poll == 1 { copy("Selected", to: pasteboard) }
                if poll == 5 { copy("New copy", to: pasteboard) }
            })
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "New copy")
        }
    }

    @Test("A real Copy during settling wins, including the same text", arguments: ["Selected", "New copy"])
    func realCopyDuringSettling(newText: String) {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, isInterrupted: { poll >= 5 }, waitForNextPoll: {
                poll += 1
                if poll == 1 { copy("Selected", to: pasteboard) }
                if poll == 5 { copy(newText, to: pasteboard) }
            })
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == newText)
            #expect(pasteboard.types?.contains(ClipboardRestoration.transientType) == false)
        }
    }

    @Test("Input before any copy arrives restores only the untouched placeholder")
    func interruptedFailedCopy() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, isInterrupted: { true }, waitForNextPoll: {})
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("Clicking away without copying restores the observed temporary selection")
    func interruptionWithoutNewClipboardWrite() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, isInterrupted: { poll >= 5 }, waitForNextPoll: {
                poll += 1
                if poll == 1 { copy("Selected", to: pasteboard) }
            })
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("A clipboard still changing at the deadline is not overwritten")
    func unsettledCopyAtDeadline() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: {
                poll += 1
                if poll == 195 { copy("Selected", to: pasteboard) }
            })
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "Selected")
        }
    }

    @Test("Data arriving after its ownership declaration can still be read")
    func delayedStringData() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            var poll = 0
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {}, waitForNextPoll: {
                poll += 1
                if poll == 1 { pasteboard.clearContents() }
                if poll == 3 { pasteboard.setString("Selected", forType: .string) }
            })
            #expect(result == "Selected")
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("A non-text copy times out and restores the original formats")
    func nonTextCopy() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {
                pasteboard.clearContents()
                pasteboard.setData(Data([1, 2]), forType: .png)
            }, waitForNextPoll: {})
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "Original")
        }
    }

    @Test("An unreadable original representation leaves the clipboard untouched")
    func unreadableSnapshotIsNotBorrowed() {
        withPasteboard { pasteboard in
            let provider = DeferredClipboardData { _, _, _ in }
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            #expect(pasteboard.writeObjects([item]))
            let count = pasteboard.changeCount
            #expect(ClipboardRestoration.begin(on: pasteboard) == nil)
            #expect(pasteboard.changeCount == count)
        }
    }

    @Test("An owner change during snapshotting prevents any temporary write")
    func changingSnapshotIsNotBorrowed() {
        withPasteboard { pasteboard in
            let provider = DeferredClipboardData { board, item, type in
                item.setString("Original", forType: type)
                self.copy("New copy during snapshot", to: board)
            }
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            #expect(pasteboard.writeObjects([item]))
            #expect(ClipboardRestoration.begin(on: pasteboard) == nil)
            #expect(pasteboard.string(forType: .string) == "New copy during snapshot")
        }
    }

    @Test("A new owner while reading copied text is never overwritten")
    func changingCopyWhileReadingIsPreserved() {
        withPasteboard { pasteboard in
            copy("Original", to: pasteboard)
            let provider = DeferredClipboardData { board, item, type in
                item.setString("Selected", forType: type)
                self.copy("New copy during read", to: board)
            }
            let result = ClipboardCopyReader.read(from: pasteboard, copy: {
                let item = NSPasteboardItem()
                item.setDataProvider(provider, forTypes: [.string])
                pasteboard.clearContents()
                #expect(pasteboard.writeObjects([item]))
            }, waitForNextPoll: {})
            #expect(result == nil)
            #expect(pasteboard.string(forType: .string) == "New copy during read")
        }
    }
}

private final class DeferredClipboardData: NSObject, NSPasteboardItemDataProvider {
    let provide: (NSPasteboard, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void

    init(_ provide: @escaping (NSPasteboard, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void) {
        self.provide = provide
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let pasteboard else { return }
        provide(pasteboard, item, type)
    }
}
