/// Keeps wake intent bound to the session that will actually receive the
/// comment. Reachability is evaluated at save time because the composer can
/// change its target after a wake shortcut pre-arms the draft.
enum CommentWakePolicy {
    static func shouldWake(
        explicitlyRequested: Bool,
        prearmed: Bool,
        targetIsReachable: Bool
    ) -> Bool {
        targetIsReachable && (explicitlyRequested || prearmed)
    }
}
