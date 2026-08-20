import Foundation

/// A parsed `remarc://comment` request.
///
/// The URL deliberately carries no selection text: Remarc re-reads its own
/// selection, so a hostile page cannot inject content into a comment. The one
/// context value it does carry is page metadata Remarc cannot see for itself,
/// and it is untrusted - a page can put anything here.
///
/// There is no `title` parameter. An earlier draft carried one, but the
/// selection is re-read locally and `source` comes from `TextReader`, so a
/// page-supplied title had no consumer - `WebContext` has no field for it, and
/// nothing else read `RemarcURLRequest.pageTitle` either. Dropped rather than
/// shipping a parser that reads untrusted input nothing uses.
public struct RemarcURLRequest: Equatable, Sendable {
    public static let scheme = "remarc"
    public static let commentHost = "comment"
    static let maxPageURLLength = 2048

    public let pageUrl: String?

    public static func parse(_ url: URL) -> RemarcURLRequest? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host?.lowercased() == commentHost else { return nil }

        // Read the raw query and decode it ourselves. The extension builds its
        // query with URLSearchParams, which serializes as
        // application/x-www-form-urlencoded and encodes a space as "+".
        // URLComponents.queryItems percent-decodes but leaves "+" untouched, so
        // relying on it turns every multi-word value into "Example+Page".
        let rawItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQueryItems ?? []
        func value(_ name: String) -> String? {
            guard let encoded = rawItems.first(where: { $0.name == name })?.value else { return nil }
            let spaced = encoded.replacingOccurrences(of: "+", with: "%20")
            guard let decoded = spaced.removingPercentEncoding, !decoded.isEmpty else { return nil }
            return decoded
        }

        var pageUrl = value("url")
        if let candidate = pageUrl {
            let parsed = URL(string: candidate)
            let scheme = parsed?.scheme?.lowercased()
            let isWebPage = scheme == "http" || scheme == "https"
            // Reject embedded userinfo ("user@host" or "user:pass@host").
            // pageUrl is rendered verbatim on comment cards, so a page could
            // otherwise dress a URL up to look like it points at a trusted
            // domain (the classic browser-bar spoof, e.g.
            // "https://accounts.google.com@evil.com/").
            let hasUserinfo = parsed?.user != nil || parsed?.password != nil
            if !isWebPage || hasUserinfo || candidate.utf8.count > maxPageURLLength {
                pageUrl = nil
            }
        }

        return RemarcURLRequest(pageUrl: pageUrl)
    }
}
