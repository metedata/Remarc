import Foundation

/// Holds `remarc://` URLs that arrive before the app has finished launching.
///
/// `applicationWillFinishLaunching` can defer setup entirely, or terminate the
/// process when a duplicate copy is already running, so a URL can land before
/// there is anything to handle it.
public struct PendingURLQueue {
    public static let maxQueued = 8

    private var queued: [URL] = []
    public private(set) var isReady = false

    public init() {}

    public mutating func enqueue(_ url: URL) {
        guard queued.count < Self.maxQueued else { return }
        queued.append(url)
    }

    public mutating func markReady() -> [URL] {
        isReady = true
        let released = queued
        queued.removeAll()
        return released
    }

    public mutating func discardAll() {
        queued.removeAll()
    }
}
