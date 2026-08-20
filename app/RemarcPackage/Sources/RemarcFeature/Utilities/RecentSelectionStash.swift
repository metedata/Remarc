import Foundation

/// Holds the selection `SelectionMonitor` most recently cleared, so a trigger
/// arriving just after a deselecting click can still find it.
///
/// Time is injected rather than read from the clock so the window is testable.
public struct RecentSelectionStash {
    private var selection: TextSelection?
    private var storedAt: CFAbsoluteTime?

    public init() {}

    public mutating func store(_ selection: TextSelection, at now: CFAbsoluteTime) {
        self.selection = selection
        self.storedAt = now
    }

    public func selection(at now: CFAbsoluteTime, maxAge: CFAbsoluteTime) -> TextSelection? {
        guard let selection, let storedAt else { return nil }
        guard now - storedAt <= maxAge else { return nil }
        return selection
    }

    public mutating func clear() {
        selection = nil
        storedAt = nil
    }
}
