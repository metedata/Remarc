import AppKit

/// A temporary use of the clipboard. Never restores over a subsequent owner.
/// Shared by selection reading and the delayed dictation paste paths.
@MainActor
struct ClipboardRestoration {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
    let changeCount: Int

    var isCurrent: Bool { pasteboard.changeCount == changeCount }

    /// Capture every representation before touching the clipboard. A failed or
    /// inconsistent snapshot must not turn into a partial/destructive restore.
    static func begin(on pasteboard: NSPasteboard, text: String? = nil) -> Self? {
        let originalChangeCount = pasteboard.changeCount
        var savedItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append((type, data))
            }
            guard !representations.isEmpty else { return nil }
            savedItems.append(representations)
        }

        let temporary = NSPasteboardItem()
        temporary.setData(Data(), forType: transientType)
        if let text { temporary.setString(text, forType: .string) }

        guard pasteboard.changeCount == originalChangeCount else { return nil }
        let changeCount = pasteboard.clearContents()
        let restoration = Self(pasteboard: pasteboard, savedItems: savedItems, changeCount: changeCount)
        guard pasteboard.writeObjects([temporary]) else {
            _ = restoration.restore()
            return nil
        }
        guard restoration.isCurrent else { return nil }
        return restoration
    }

    /// Prepare the whole write before the final ownership check, then publish
    /// all items together. Existing confidential markers and their payloads are
    /// preserved; ordinary contents must never be newly labelled confidential.
    @discardableResult
    func restore(ifUnchangedSince expectedChangeCount: Int? = nil) -> Bool {
        let restored = savedItems.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            if !item.types.contains(Self.transientType) {
                item.setData(Data(), forType: Self.transientType)
            }
            return item
        }
        let items: [NSPasteboardItem]
        if restored.isEmpty {
            // No user data, but still identify the empty restore as housekeeping.
            let marker = NSPasteboardItem()
            marker.setData(Data(), forType: Self.transientType)
            items = [marker]
        } else {
            items = restored
        }

        guard pasteboard.changeCount == (expectedChangeCount ?? changeCount) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}

/// Reads a synthetic copy while checking for competing input and clipboard writes.
@MainActor
enum ClipboardCopyReader {
    static func read(
        from pasteboard: NSPasteboard,
        copy: () -> Void,
        isInterrupted: () -> Bool = { false },
        maximumPolls: Int = 200,
        settlingPolls: Int = 30,
        waitForNextPoll: () -> Void = { usleep(2_000) }
    ) -> String? {
        guard let restoration = ClipboardRestoration.begin(on: pasteboard) else { return nil }
        // This baseline is AFTER our own clear/write, which is not a successful copy.
        var copyChangeCount: Int?
        var copiedText: String?
        var quietPolls = 0
        copy()

        for _ in 0..<maximumPolls {
            waitForNextPoll()
            guard !isInterrupted() else {
                // A new key/click may be a real Copy, including identical text.
                // Restore only the last state we actually observed. If the new
                // input has already copied anything, this ownership check fails.
                _ = restoration.restore(ifUnchangedSince: copyChangeCount ?? restoration.changeCount)
                return nil
            }
            let current = pasteboard.changeCount
            if current == restoration.changeCount { continue }

            // One Copy is not necessarily one changeCount increment. Chromium
            // apps can publish the same selection in several stages. Wait for
            // those writes to settle, but never adopt different text as our copy.
            if current != copyChangeCount || copiedText == nil {
                let text = pasteboard.string(forType: .string)
                guard pasteboard.changeCount == current else { return nil }
                if let copiedText, text != copiedText { return nil }
                if let text { copiedText = text }
            }
            if current != copyChangeCount {
                copyChangeCount = current
                quietPolls = 0
            } else {
                quietPolls += 1
            }
            guard let copiedText, quietPolls >= settlingPolls else { continue }
            guard !isInterrupted() else {
                _ = restoration.restore(ifUnchangedSince: current)
                return nil
            }
            guard restoration.restore(ifUnchangedSince: current) else { return nil }
            return copiedText
        }

        // A timeout alone never grants ownership of a clipboard that is still
        // changing. Restore a failed/non-text copy only after it has settled.
        if isInterrupted() || copyChangeCount == nil || quietPolls >= settlingPolls {
            _ = restoration.restore(ifUnchangedSince: copyChangeCount ?? restoration.changeCount)
        }
        return nil
    }
}
