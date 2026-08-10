enum RemarcEditorVoiceTarget: Equatable {
    case commentInput
    case floatingEditor
}

enum RemarcEditorVoiceRouter {
    static func activeTarget(
        commentInputVisible: Bool,
        floatingEditorVisible: Bool
    ) -> RemarcEditorVoiceTarget? {
        if floatingEditorVisible {
            return .floatingEditor
        }
        if commentInputVisible {
            return .commentInput
        }
        return nil
    }
}
