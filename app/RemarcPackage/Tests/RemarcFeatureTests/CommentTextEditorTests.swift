import AppKit
import SwiftUI
import Testing
@testable import RemarcFeature

@Suite("Comment text editor")
struct CommentTextEditorTests {
    @Test("Command-Return uses the callbacks from the latest SwiftUI update")
    @MainActor
    func commandReturnUsesLatestCallback() throws {
        var submittedValue = ""
        let coordinator = CommentTextEditor.Coordinator(
            text: .constant("old"),
            onSubmit: { submittedValue = "old" },
            onCancel: {},
            onImagePaste: nil,
            onContentHeightChange: nil
        )
        coordinator.update(
            text: .constant("new"),
            onSubmit: { submittedValue = "new" },
            onCancel: {},
            onImagePaste: nil,
            onContentHeightChange: nil
        )

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        #expect(coordinator.textView(InterceptingTextView(), shouldHandleKeyDown: event))
        #expect(submittedValue == "new")
        #expect(coordinator.text.wrappedValue == "new")
    }
}
