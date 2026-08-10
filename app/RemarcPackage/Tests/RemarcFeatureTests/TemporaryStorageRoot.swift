import Foundation
import XCTest
@testable import RemarcFeature

/// Redirects every storage path helper at a throwaway directory for one test.
///
/// The annotation suites used to write into the user's live
/// `~/Library/Application Support/Remarc`. That produced three separate
/// problems, all observed: stray images accumulated in real data, a case that
/// failed before its teardown left a deliberately corrupt sidecar behind for
/// the running app to find and log as corruption, and two concurrent `swift
/// test` runs contended over the same files until one hung.
///
/// Install it in `setUp` and tear it down in `tearDown`. Cleanup removes the
/// whole tree, so individual tests no longer have to track what they created.
struct TemporaryStorageRoot {
    let url: URL

    init(function: StaticString = #function) {
        // Named after the test so a leaked directory says which one leaked it.
        let name = "RemarcTests-\(function)-\(UUID().uuidString)"
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
    }

    func install() throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true)
        remarcAppSupportOverride = url
    }

    func remove() {
        // Cleared before the delete: a later test resolving paths against a
        // directory that no longer exists is a worse failure than a leaked one.
        remarcAppSupportOverride = nil
        try? FileManager.default.removeItem(at: url)
    }
}
