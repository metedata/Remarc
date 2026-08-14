import Testing
@testable import RemarcFeature

@Suite("Comment wake policy")
struct CommentWakePolicyTests {
    @Test("Pre-armed wake is retained for a reachable target")
    func prearmedReachableTarget() {
        #expect(CommentWakePolicy.shouldWake(
            explicitlyRequested: false,
            prearmed: true,
            targetIsReachable: true
        ))
    }

    @Test("Pre-armed wake is dropped after switching to an unreachable target")
    func prearmedUnreachableTarget() {
        #expect(!CommentWakePolicy.shouldWake(
            explicitlyRequested: false,
            prearmed: true,
            targetIsReachable: false
        ))
    }

    @Test("Explicit wake is also revalidated at save time")
    func explicitWakeRequiresReachableTarget() {
        #expect(!CommentWakePolicy.shouldWake(
            explicitlyRequested: true,
            prearmed: false,
            targetIsReachable: false
        ))
    }
}
