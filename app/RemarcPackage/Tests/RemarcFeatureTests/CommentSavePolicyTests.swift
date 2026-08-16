import Testing
@testable import RemarcFeature

@Suite("Comment save policy")
struct CommentSavePolicyTests {
    @Test(
        "Quick Notes require meaningful text",
        arguments: ["", "   ", "\n\t "]
    )
    func rejectsEmptyQuickNotes(_ text: String) {
        #expect(!CommentSavePolicy.allowsSave(type: .quickNote, commentText: text))
    }

    @Test("Attachments do not make an empty Quick Note valid")
    func rejectsAttachmentOnlyQuickNote() {
        #expect(!CommentSavePolicy.allowsSave(
            type: .quickNote,
            commentText: "",
            attachments: ["attachment.png"]
        ))
    }

    @Test("Quick Notes allow meaningful text")
    func allowsQuickNoteText() {
        #expect(CommentSavePolicy.allowsSave(type: .quickNote, commentText: "  Keep this  "))
    }

    @Test("Text selections can be saved without a body")
    func allowsContextOnlyTextSelection() {
        #expect(CommentSavePolicy.allowsSave(type: .comment(text: "Selected context"), commentText: " \n "))
    }

    @Test("Screenshots can be saved without a body")
    func allowsContextOnlyScreenshot() {
        #expect(CommentSavePolicy.allowsSave(type: .screenshot(imagePath: "capture.png"), commentText: ""))
    }

    @Test("Web elements can be saved without a body")
    func allowsContextOnlyWebElement() {
        #expect(CommentSavePolicy.allowsSave(
            type: .webElement(componentName: "SaveButton", filePath: "Editor.swift"),
            commentText: "\t"
        ))
    }

    @Test("Crit Mode keeps its existing empty-text behavior")
    func leavesCritModeUnchanged() {
        #expect(CommentSavePolicy.allowsSave(type: .critMode, commentText: ""))
    }

    @Test(
        "Empty selections remain Quick Notes",
        arguments: ["", "   ", "\n\t "]
    )
    func classifiesEmptySelectionAsQuickNote(_ text: String) {
        #expect(CommentSavePolicy.type(forSelectionText: text) == .quickNote)
    }

    @Test("Meaningful selections classify as contextual comments")
    func classifiesMeaningfulSelectionAsComment() {
        #expect(CommentSavePolicy.type(forSelectionText: "  Selected context  ") == .comment(text: "Selected context"))
    }
}
