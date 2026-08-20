enum WebContextAttachmentPolicy {
    /// Resolves which web context, if any, a comment should be saved with.
    ///
    /// Precedence: live Chrome extension context (only when the source is
    /// Chromium), then a Chrome DOM element grab, then page context adopted
    /// from a non-Chromium trigger (currently the `remarc://` PopClip path),
    /// then none. A Chromium source with no live extension context (Arc,
    /// Brave, or Chrome itself before the extension has ever connected) falls
    /// through to element/external context rather than stopping at nil.
    static func resolve(
        isChromium: Bool,
        liveChromeContext: WebContext?,
        elementContext: WebContext?,
        externalPageContext: WebContext?
    ) -> WebContext? {
        if isChromium, let liveChromeContext {
            liveChromeContext
        } else if let elementContext {
            elementContext
        } else if let externalPageContext {
            externalPageContext
        } else {
            nil
        }
    }
}
