import Testing
@testable import RemarcFeature

@Suite("Dictation editor routing")
struct DictationEditorRoutingTests {
    @Test("Routes dictation into the quick note editor when it is visible")
    func routesToFloatingQuickNoteEditor() {
        #expect(
            RemarcEditorVoiceRouter.activeTarget(
                commentInputVisible: false,
                floatingEditorVisible: true
            ) == .floatingEditor
        )
    }

    @Test("Routes dictation into the selection comment input when it is visible")
    func routesToCommentInput() {
        #expect(
            RemarcEditorVoiceRouter.activeTarget(
                commentInputVisible: true,
                floatingEditorVisible: false
            ) == .commentInput
        )
    }

    @Test("Uses normal dictation when no Remarc editor is visible")
    func noEditorUsesGlobalDictation() {
        #expect(
            RemarcEditorVoiceRouter.activeTarget(
                commentInputVisible: false,
                floatingEditorVisible: false
            ) == nil
        )
    }
}
