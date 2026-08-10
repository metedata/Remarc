import Foundation
import Testing
@testable import RemarcFeature

// MARK: - Helpers

private func makeComment(
    id: UUID = UUID(),
    text: String = "Fix the button color",
    selected: String = "Submit",
    status: CommentStatus = .open,
    sessionID: UUID = UUID(),
    isDeleted: Bool = false,
    attachments: [String] = []
) -> RemarcFeature.Comment {
    RemarcFeature.Comment(
        id: id,
        type: .comment(text: selected),
        commentText: text,
        source: "Safari",
        appBundleID: "com.apple.Safari",
        sessionID: sessionID,
        isDeleted: isDeleted,
        status: status,
        attachments: attachments
    )
}

// MARK: - Payload

@Test func webhookDefaultPayloadContainsExpectedFields() throws {
    let sessionID = UUID()
    let comment = makeComment(sessionID: sessionID)
    let body = WebhookService.buildDefaultBody(
        event: .commentResolved,
        comment: comment,
        sessionName: "Inbox",
        sessionID: sessionID,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "1.2.3"
    )

    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["event"] as? String == "comment.resolved")
    #expect((json["timestamp"] as? String)?.hasPrefix("2023-11-14T") == true)

    let app = try #require(json["app"] as? [String: Any])
    #expect(app["name"] as? String == "Remarc")
    #expect(app["version"] as? String == "1.2.3")

    let session = try #require(json["session"] as? [String: Any])
    #expect(session["name"] as? String == "Inbox")
    #expect(session["id"] as? String == sessionID.uuidString)

    let commentJSON = try #require(json["comment"] as? [String: Any])
    #expect(commentJSON["commentText"] as? String == "Fix the button color")
    #expect(commentJSON["shortID"] as? String == comment.shortID)
    #expect(commentJSON["status"] as? String == "open")
    #expect(commentJSON["source"] as? String == "Safari")
    // Dates inside the comment must be ISO8601 strings, not numbers
    #expect(commentJSON["createdAt"] is String)
}

@Test func webhookPayloadOmitsSessionWhenUnknown() throws {
    let body = WebhookService.buildDefaultBody(
        event: .commentCreated,
        comment: makeComment(),
        sessionName: nil,
        sessionID: nil,
        timestamp: Date(),
        appVersion: "1.0"
    )
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["session"] == nil)
}

// MARK: - Signing

@Test func webhookSignatureMatchesKnownVector() {
    // Vector computed independently with Python's hmac/hashlib:
    // key=b"testsecret", msg=b"msg_1.1700000000.{\"a\":1}"
    let signature = WebhookService.signature(
        secret: "testsecret",
        id: "msg_1",
        timestamp: "1700000000",
        body: Data("{\"a\":1}".utf8)
    )
    #expect(signature == "v1,7BRwrYykyX6T5HEsHzolAivlaS2kAJ5bzSgjAJ5tKf8=")
}

@Test func webhookSignatureDecodesWhsecPrefix() {
    // "whsec_dGVzdHNlY3JldA==" base64-decodes to "testsecret", so both forms
    // must produce identical signatures.
    let body = Data("{\"a\":1}".utf8)
    let raw = WebhookService.signature(secret: "testsecret", id: "msg_1", timestamp: "1700000000", body: body)
    let prefixed = WebhookService.signature(secret: "whsec_dGVzdHNlY3JldA==", id: "msg_1", timestamp: "1700000000", body: body)
    #expect(raw == prefixed)
}

@Test func webhookSignatureIgnoresPastedWhitespace() {
    // A trailing newline or space from copy-paste must not change the key.
    let body = Data("{\"a\":1}".utf8)
    let clean = WebhookService.signature(secret: "whsec_dGVzdHNlY3JldA==", id: "msg_1", timestamp: "1700000000", body: body)
    let newline = WebhookService.signature(secret: "whsec_dGVzdHNlY3JldA==\n", id: "msg_1", timestamp: "1700000000", body: body)
    let spaces = WebhookService.signature(secret: "  whsec_dGVzdHNlY3JldA== ", id: "msg_1", timestamp: "1700000000", body: body)
    #expect(clean == newline)
    #expect(clean == spaces)
}

@Test func webhookSignatureAcceptsBase64urlAndUnpadded() {
    let body = Data("{\"a\":1}".utf8)
    let padded = WebhookService.signature(secret: "whsec_dGVzdHNlY3JldA==", id: "msg_1", timestamp: "1700000000", body: body)
    let unpadded = WebhookService.signature(secret: "whsec_dGVzdHNlY3JldA", id: "msg_1", timestamp: "1700000000", body: body)
    #expect(padded == unpadded)
}

@Test func webhookSignatureMalformedWhsecFallsBackWithoutPrefix() {
    // When the whsec_ remainder is not decodable, the key must be the raw
    // remainder bytes, never the transport prefix.
    let body = Data("{\"a\":1}".utf8)
    let malformed = WebhookService.signature(secret: "whsec_!!!", id: "msg_1", timestamp: "1700000000", body: body)
    let bare = WebhookService.signature(secret: "!!!", id: "msg_1", timestamp: "1700000000", body: body)
    #expect(malformed == bare)
}

// MARK: - Templating

@Test func webhookTemplateSubstitutesAndEscapes() throws {
    let comment = makeComment(text: "Line1\nLine2 with \"quotes\" and \\backslash")
    let body = WebhookService.renderTemplate(
        "{\"text\": \"{{comment.text}}\", \"event\": \"{{event}}\"}",
        event: .commentCreated,
        comment: comment,
        sessionName: "Inbox",
        sessionID: UUID(),
        timestamp: Date()
    )

    // The rendered output must still be valid JSON despite the hostile input.
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["text"] as? String == "Line1\nLine2 with \"quotes\" and \\backslash")
    #expect(json["event"] as? String == "comment.created")
}

@Test func webhookTemplateDoesNotResubstituteTokensInsideValues() throws {
    // Comment content containing a literal {{token}} must stay literal - a
    // multi-pass renderer would expand it via a later substitution.
    let comment = makeComment(text: "rename {{session.name}} to X")
    let body = WebhookService.renderTemplate(
        "{\"text\": \"{{comment.text}}\"}",
        event: .commentCreated,
        comment: comment,
        sessionName: "Inbox",
        sessionID: UUID(),
        timestamp: Date()
    )
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["text"] as? String == "rename {{session.name}} to X")
}

@Test func webhookTemplateSubstitutesTokenAfterStrayBraces() {
    let body = WebhookService.renderTemplate(
        "{{ stray {{comment.shortID}}",
        event: .commentCreated,
        comment: makeComment(),
        sessionName: nil,
        sessionID: nil,
        timestamp: Date()
    )
    let rendered = String(decoding: body, as: UTF8.self)
    #expect(rendered.hasPrefix("{{ stray "))
    #expect(!rendered.contains("{{comment.shortID}}"))
}

@Test func webhookTemplateLeavesUnknownPlaceholdersIntact() {
    let body = WebhookService.renderTemplate(
        "{{not.a.thing}} {{comment.shortID}}",
        event: .commentSent,
        comment: makeComment(),
        sessionName: nil,
        sessionID: nil,
        timestamp: Date()
    )
    let rendered = String(decoding: body, as: UTF8.self)
    #expect(rendered.hasPrefix("{{not.a.thing}} "))
    #expect(!rendered.contains("{{comment.shortID}}"))
}

@Test func webhookJSONEscapeHandlesControlCharacters() {
    #expect(WebhookService.jsonEscape("a\"b") == "a\\\"b")
    #expect(WebhookService.jsonEscape("a\\b") == "a\\\\b")
    #expect(WebhookService.jsonEscape("a\nb") == "a\\nb")
    #expect(WebhookService.jsonEscape("a\tb") == "a\\tb")
    #expect(WebhookService.jsonEscape("a\u{01}b") == "a\\u0001b")
    #expect(WebhookService.jsonEscape("plain") == "plain")
}

// MARK: - Reload Diff

@Test func webhookDiffDetectsCreation() {
    let existing = makeComment()
    let created = makeComment()
    let events = WebhookEventDiff.events(old: [existing], new: [existing, created])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentCreated)
    #expect(events[0].1.id == created.id)
}

@Test func webhookDiffIgnoresCommentsArrivingAlreadyDeleted() {
    let deleted = makeComment(isDeleted: true)
    let events = WebhookEventDiff.events(old: [], new: [deleted])
    #expect(events.isEmpty)
}

@Test func webhookDiffMapsResolvedStatusToResolvedEvent() {
    let id = UUID()
    let before = makeComment(id: id, status: .open)
    var after = before
    after.status = .resolved
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentResolved)
}

@Test func webhookDiffMapsOtherStatusToStatusChanged() {
    let id = UUID()
    let before = makeComment(id: id, status: .open)
    var after = before
    after.status = .inProgress
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentStatusChanged)
}

@Test func webhookDiffDetectsSoftDelete() {
    let before = makeComment()
    var after = before
    after.isDeleted = true
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentDeleted)
}

@Test func webhookDiffDetectsTextEdit() {
    let before = makeComment()
    var after = before
    after.commentText = "Edited"
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentUpdated)
}

@Test func webhookDiffDetectsSessionMove() {
    let before = makeComment()
    var after = before
    after.sessionID = UUID()
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.count == 1)
    #expect(events[0].0 == .commentUpdated)
}

@Test func webhookDiffEmitsStatusAndUpdateTogether() {
    let before = makeComment()
    var after = before
    after.status = .inProgress
    after.commentText = "Edited too"
    let events = WebhookEventDiff.events(old: [before], new: [after])
    #expect(events.map(\.0) == [.commentStatusChanged, .commentUpdated])
}

@Test func webhookDiffStaysSilentOnRestoreAndPrune() {
    let restored = makeComment(isDeleted: true)
    var restoredAfter = restored
    restoredAfter.isDeleted = false

    let pruned = makeComment()
    // pruned exists in old but not in new (hard-removed by retention)
    let events = WebhookEventDiff.events(old: [restored, pruned], new: [restoredAfter])
    #expect(events.isEmpty)
}

@Test func webhookDiffSuppressesSessionCascadeDeletes() {
    // A session deleted out-of-process (e.g. Claude Code wind-down) soft-deletes
    // its comments in the same write. Those deletes are cascade housekeeping and
    // must be silent, matching the in-app deleteSession behavior.
    let session = Session(name: "Agent Session")
    let before = makeComment(sessionID: session.id)
    var after = before
    after.isDeleted = true
    var deadSession = session
    deadSession.isDeleted = true

    let events = WebhookEventDiff.events(
        old: [before], new: [after],
        oldSessions: [session], newSessions: [deadSession]
    )
    #expect(events.isEmpty)
}

@Test func webhookDiffSuppressesAutoDismissCascadeDeletes() {
    let session = Session(name: "Agent Session")
    let before = makeComment(sessionID: session.id)
    var after = before
    after.isDeleted = true
    var dismissed = session
    dismissed.isAutoDismissed = true

    let events = WebhookEventDiff.events(
        old: [before], new: [after],
        oldSessions: [session], newSessions: [dismissed]
    )
    #expect(events.isEmpty)
}

@Test func webhookDiffStillFiresDeleteInLiveSession() {
    // A comment deleted inside a session that stays live is a real signal.
    let session = Session(name: "Live Session")
    let before = makeComment(sessionID: session.id)
    var after = before
    after.isDeleted = true

    let events = WebhookEventDiff.events(
        old: [before], new: [after],
        oldSessions: [session], newSessions: [session]
    )
    #expect(events.map(\.0) == [.commentDeleted])
}

@Test func webhookDiffDoesNotSuppressDeletesInAlreadyDeadSession() {
    // Session was ALREADY deleted before this reload - a comment delete inside
    // it is not part of a cascade transition and still fires.
    var deadSession = Session(name: "Old Session")
    deadSession.isDeleted = true
    let before = makeComment(sessionID: deadSession.id)
    var after = before
    after.isDeleted = true

    let events = WebhookEventDiff.events(
        old: [before], new: [after],
        oldSessions: [deadSession], newSessions: [deadSession]
    )
    #expect(events.map(\.0) == [.commentDeleted])
}

@Test func webhookDiffStaysSilentWhenNothingChanged() {
    let a = makeComment()
    let b = makeComment(status: .resolved)
    let events = WebhookEventDiff.events(old: [a, b], new: [a, b])
    #expect(events.isEmpty)
}

// MARK: - Model

@Test func webhookCodableRoundTrip() throws {
    let original = Webhook(
        name: "Zapier",
        url: "https://hooks.zapier.com/hooks/catch/1/abc",
        isEnabled: false,
        events: [.commentResolved, .commentDeleted],
        secret: "whsec_dGVzdHNlY3JldA==",
        customTemplate: "{\"text\": \"{{comment.text}}\"}"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Webhook.self, from: data)
    #expect(decoded == original)
}

@Test func webhookURLValidation() {
    #expect(Webhook(url: "https://example.com/hook").hasValidURL)
    #expect(Webhook(url: "http://127.0.0.1:8471/hook").hasValidURL)
    #expect(!Webhook(url: "ftp://example.com").hasValidURL)
    #expect(!Webhook(url: "file:///etc/passwd").hasValidURL)
    #expect(!Webhook(url: "not a url").hasValidURL)
    #expect(!Webhook(url: "").hasValidURL)
    #expect(!Webhook(url: "https://").hasValidURL)
}

@Test func webhookDefaultSubscribesToAllSubscribableEvents() {
    let webhook = Webhook()
    #expect(webhook.events == Set(WebhookEventType.subscribable))
    #expect(!webhook.events.contains(.commentSent))
    #expect(!webhook.events.contains(.webhookTest))
}
