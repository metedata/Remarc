import Foundation
import Testing
@testable import RemarcFeature

@Suite("Remarc URL request")
struct RemarcURLRequestTests {
    @Test("A bare comment URL parses with no context")
    func bareCommentURL() {
        let request = RemarcURLRequest.parse(URL(string: "remarc://comment")!)
        #expect(request != nil)
        #expect(request?.pageUrl == nil)
    }

    @Test("Browser url is captured")
    func browserContextCaptured() {
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa")!
        let request = RemarcURLRequest.parse(url)
        #expect(request?.pageUrl == "https://example.com/a")
    }

    /// The extension builds its query with URLSearchParams, which serializes as
    /// application/x-www-form-urlencoded and therefore encodes a space as "+".
    /// URLComponents.queryItems percent-decodes but leaves "+" alone, so without
    /// explicit handling every multi-word value arrives with plus signs in it.
    /// This is the exact encoding the shipped extension emits - do not
    /// "simplify" it to %20, which is what hid this bug in the first draft.
    /// Originally pinned on `title` (now removed); retargeted to `pageUrl`,
    /// the only field left that goes through this decoding.
    @Test("Plus-encoded spaces from URLSearchParams decode to spaces")
    func plusEncodedSpacesDecode() {
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa+b")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == "https://example.com/a b")
    }

    @Test("A literal plus in a page url survives decoding")
    func literalPlusInURLSurvives() {
        // %2B is how a real "+" in a URL is encoded, and it must not become a space.
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Fexample.com%2Fa%2Bb")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == "https://example.com/a+b")
    }

    @Test("An unknown host is rejected")
    func unknownHostRejected() {
        #expect(RemarcURLRequest.parse(URL(string: "remarc://export?url=x")!) == nil)
    }

    @Test("A foreign scheme is rejected")
    func foreignSchemeRejected() {
        #expect(RemarcURLRequest.parse(URL(string: "https://comment")!) == nil)
    }

    @Test("An oversized page url is dropped rather than stored")
    func oversizedPageURLDropped() {
        let long = String(repeating: "a", count: 3000)
        let url = URL(string: "remarc://comment?url=https://example.com/\(long)")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }

    /// `oversizedPageURLDropped` above is all-ASCII, where `count` (grapheme
    /// clusters) and `utf8.count` (bytes) agree, so it cannot tell a byte-length
    /// cap apart from a character-length one. "é" is a single Swift `Character`
    /// but 2 UTF-8 bytes, so 1500 of them push `utf8.count` over the 2048 cap
    /// while `count` stays comfortably under it. If the cap ever regresses to
    /// `.count`, this is the test that catches it - `oversizedPageURLDropped`
    /// would keep passing.
    @Test("An oversized page url is dropped by UTF-8 byte length even under the character cap")
    func oversizedPageURLDroppedByUTF8BytesEvenUnderCharacterCap() {
        let candidate = "https://example.com/" + String(repeating: "é", count: 1500)
        #expect(candidate.count == 1520)
        #expect(candidate.utf8.count == 3020)
        let url = URL(string: "remarc://comment?url=\(candidate)")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }

    @Test("Empty parameter values are treated as absent")
    func emptyValuesAreAbsent() {
        let request = RemarcURLRequest.parse(URL(string: "remarc://comment?url=")!)
        #expect(request?.pageUrl == nil)
    }

    @Test("A non-http page url is rejected")
    func nonHTTPPageURLRejected() {
        let url = URL(string: "remarc://comment?url=javascript%3Aalert(1)")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }

    @Test("A page url with embedded userinfo is rejected")
    func pageURLWithUserinfoRejected() {
        // "user@host" before the real host lets a page dress a URL up to
        // look like it points at a trusted domain - everything before the
        // last "@" is credentials, not the host. pageUrl is rendered
        // verbatim on comment cards, so this must be dropped, not stored.
        let url = URL(string: "remarc://comment?url=https%3A%2F%2Faccounts.google.com%40evil.com%2F")!
        #expect(RemarcURLRequest.parse(url)?.pageUrl == nil)
    }
}
