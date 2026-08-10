import Testing
@testable import RemarcFeature

@Suite("Screenshot web context policy")
struct ScreenshotWebContextPolicyTests {
    @Test("non-browser screenshots ignore browser web context")
    func nonBrowserScreenshotsIgnoreBrowserWebContext() {
        #expect(!ScreenshotWebContextPolicy.allowsWebContext(sourceBundleID: "com.openai.codex"))
    }

    @Test("Chromium screenshots can attach web context")
    func chromiumScreenshotsCanAttachWebContext() {
        #expect(ScreenshotWebContextPolicy.allowsWebContext(sourceBundleID: "com.google.Chrome"))
    }

    @Test("unknown screenshot source does not attach web context")
    func unknownScreenshotSourceDoesNotAttachWebContext() {
        #expect(!ScreenshotWebContextPolicy.allowsWebContext(sourceBundleID: nil))
    }
}
