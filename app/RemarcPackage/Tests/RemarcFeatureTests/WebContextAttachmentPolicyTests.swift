import Testing
@testable import RemarcFeature

@Suite("Web context attachment policy")
struct WebContextAttachmentPolicyTests {
    private let live = WebContext(pageUrl: "https://live.example/")
    private let element = WebContext(pageUrl: "https://element.example/")
    private let external = WebContext(pageUrl: "https://external.example/")

    @Test("A Chromium source with live extension context prefers it over element or external context")
    func chromiumPrefersLiveContext() {
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: true,
            liveChromeContext: live,
            elementContext: element,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == live.pageUrl)
    }

    @Test("A Chromium source with no live extension context falls through to element context")
    func chromiumFallsThroughToElementWhenLiveIsAbsent() {
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: true,
            liveChromeContext: nil,
            elementContext: element,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == element.pageUrl)
    }

    @Test("A Chromium source with neither live nor element context falls through to external context")
    func chromiumFallsThroughToExternalWhenLiveAndElementAreAbsent() {
        // This is the Arc/Brave case: a Chromium browser with no extension
        // connected still gets PopClip's page-URL fallback, instead of nil.
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: true,
            liveChromeContext: nil,
            elementContext: nil,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == external.pageUrl)
    }

    @Test("A non-Chromium source never uses live context, even if some is passed in")
    func nonChromiumIgnoresLiveContext() {
        // Guards against a regression where live context leaks into a
        // non-Chromium comment merely because the caller happened to pass one.
        // The real caller only ever passes a non-nil liveChromeContext when
        // isChromium is also true, but the policy itself must not depend on
        // that discipline.
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: false,
            liveChromeContext: live,
            elementContext: nil,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == external.pageUrl)
    }

    @Test("A non-Chromium source prefers element context over external context")
    func nonChromiumPrefersElementOverExternal() {
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: false,
            liveChromeContext: nil,
            elementContext: element,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == element.pageUrl)
    }

    @Test("A non-Chromium source with only external context uses it - the PopClip/Safari case")
    func nonChromiumUsesExternalContextAlone() {
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: false,
            liveChromeContext: nil,
            elementContext: nil,
            externalPageContext: external
        )
        #expect(resolved?.pageUrl == external.pageUrl)
    }

    @Test("Nothing pending resolves to nil")
    func nothingPendingResolvesToNil() {
        let resolved = WebContextAttachmentPolicy.resolve(
            isChromium: false,
            liveChromeContext: nil,
            elementContext: nil,
            externalPageContext: nil
        )
        #expect(resolved == nil)
    }
}
