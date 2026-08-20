import Foundation
import Testing
@testable import RemarcFeature

// PopClipInstaller is @MainActor (a real AppKit/NSWorkspace dependency, not a
// convenience marker), so the suite needs the same annotation to call its
// static methods synchronously. Matches the WebSocketServiceTests precedent.
@MainActor
@Suite("PopClip installer")
struct PopClipInstallerTests {
    @Test("PopClip counts as installed when the bundle identifier resolves")
    func installedWhenResolved() {
        #expect(PopClipInstaller.isInstalled { _ in URL(fileURLWithPath: "/Applications/PopClip.app") })
    }

    @Test("PopClip counts as absent when the bundle identifier does not resolve")
    func absentWhenUnresolved() {
        #expect(!PopClipInstaller.isInstalled { _ in nil })
    }

    @Test("Only PopClip's bundle identifier is queried")
    func queriesPopClipIdentifier() {
        var queried: [String] = []
        _ = PopClipInstaller.isInstalled { identifier in
            queried.append(identifier)
            return nil
        }
        #expect(queried == ["com.pilotmoon.popclip"])
    }

    @Test("The bundled package path sits in the app's Resources")
    func bundledPackagePath() {
        // isDirectory: true because this stands in for Bundle.main.resourceURL,
        // which always points at a real, existing directory. Without the hint,
        // URL(fileURLWithPath:) infers non-directory for a nonexistent path,
        // while deletingLastPathComponent() always returns a directory URL
        // (trailing slash) - a mismatch that is a Foundation URL-equality
        // quirk, not a property of the code under test.
        let base = URL(fileURLWithPath: "/tmp/Remarc.app/Contents/Resources", isDirectory: true)
        let package = PopClipInstaller.bundledPackageURL(in: base)
        #expect(package.lastPathComponent == "Remarc.popclipext")
        #expect(package.deletingLastPathComponent() == base)
    }
}
