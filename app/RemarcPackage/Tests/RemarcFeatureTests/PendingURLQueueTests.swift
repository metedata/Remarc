import Foundation
import Testing
@testable import RemarcFeature

@Suite("Pending URL queue")
struct PendingURLQueueTests {
    private let a = URL(string: "remarc://comment?url=https://example.com/a")!
    private let b = URL(string: "remarc://comment?url=https://example.com/b")!

    @Test("URLs enqueued before ready are released in order on markReady")
    func queuedUntilReady() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        queue.enqueue(b)
        #expect(queue.markReady() == [a, b])
    }

    @Test("markReady returns nothing the second time")
    func markReadyDrains() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        _ = queue.markReady()
        #expect(queue.markReady().isEmpty)
    }

    @Test("Once ready, the queue reports ready so callers handle URLs directly")
    func readyFlagFlips() {
        var queue = PendingURLQueue()
        #expect(!queue.isReady)
        _ = queue.markReady()
        #expect(queue.isReady)
    }

    @Test("discardAll drops queued URLs and leaves the queue not ready")
    func discardDrops() {
        var queue = PendingURLQueue()
        queue.enqueue(a)
        queue.discardAll()
        #expect(!queue.isReady)
        #expect(queue.markReady().isEmpty)
    }

    @Test("The queue is bounded so a flood cannot grow without limit")
    func queueIsBounded() {
        var queue = PendingURLQueue()
        for _ in 0..<50 { queue.enqueue(a) }
        // Exact count, not `<=`: a queue that silently dropped everything
        // would also satisfy `<=`, so this must pin the cap itself.
        #expect(queue.markReady().count == PendingURLQueue.maxQueued)
    }
}
