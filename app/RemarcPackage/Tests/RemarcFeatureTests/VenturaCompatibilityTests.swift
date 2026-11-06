import AppKit
import Combine
import XCTest
@testable import RemarcFeature

@MainActor
final class VenturaCompatibilityTests: XCTestCase {
    func testArrowKeysLeaveTextEditingAndModifiedShortcutsAlone() throws {
        func event(_ key: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key
            ))
        }
        XCTAssertEqual(ArrowKeyNavigationView.direction(for: try event(125), firstResponder: nil), 1)
        XCTAssertEqual(ArrowKeyNavigationView.direction(for: try event(126), firstResponder: nil), -1)
        XCTAssertNil(ArrowKeyNavigationView.direction(for: try event(125), firstResponder: NSTextView()))
        XCTAssertNil(ArrowKeyNavigationView.direction(for: try event(126), firstResponder: NSTextField()))
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertNil(ArrowKeyNavigationView.direction(for: try event(125, flags: flag), firstResponder: nil))
        }
        XCTAssertNil(ArrowKeyNavigationView.direction(for: try event(53), firstResponder: nil))
    }

    func testToastPublishesShowReplacementAndDismissal() {
        let manager = ToastManager()
        var messages: [String?] = []
        let subscription = manager.$currentToast.sink { messages.append($0?.message) }
        manager.show("Saved")
        manager.show("Deleted")
        manager.dismiss()
        XCTAssertEqual(messages, [nil, "Saved", "Deleted", nil])
        withExtendedLifetime(subscription) {}
    }

    func testEngineChoicesMatchLinkedBackends() {
        #if canImport(FluidAudio)
        XCTAssertTrue(TranscriptionEngineType.availableCases.contains(.parakeet))
        #else
        XCTAssertEqual(TranscriptionEngineType.availableCases, [.appleSpeech, .whisperKit])
        #endif
    }
}
