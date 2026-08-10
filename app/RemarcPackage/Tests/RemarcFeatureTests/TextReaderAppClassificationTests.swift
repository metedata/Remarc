import Testing
@testable import RemarcFeature

@MainActor
@Suite("TextReader app classification")
struct TextReaderAppClassificationTests {
    @Test("Claude Code terminal hosts can publish selection to pasteboard")
    func terminalHostsMayPublishSelectionToClipboard() {
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "dev.warp.Warp-Stable"))
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "com.apple.Terminal"))
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "com.googlecode.iterm2"))
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "com.mitchellh.ghostty"))
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "com.microsoft.VSCode"))
        #expect(TextReader.appMayPublishSelectionToClipboard(bundleID: "com.todesktop.230313mzl4w4u92"))
    }

    @Test("Non-terminal apps do not use passive pasteboard fallback")
    func nonTerminalAppsDoNotUsePassivePasteboardFallback() {
        #expect(!TextReader.appMayPublishSelectionToClipboard(bundleID: "com.apple.finder"))
        #expect(!TextReader.appMayPublishSelectionToClipboard(bundleID: "company.thebrowser.Browser"))
    }

    @Test("GPU rendered apps keep simulated clipboard fallback")
    func gpuRenderedAppsNeedClipboardFallback() {
        #expect(TextReader.appNeedsClipboardFallback(bundleID: "dev.warp.Warp-Stable"))
        #expect(TextReader.appNeedsClipboardFallback(bundleID: "dev.zed.Zed"))
        #expect(TextReader.appNeedsClipboardFallback(bundleID: "com.jetbrains.intellij"))
        #expect(!TextReader.appNeedsClipboardFallback(bundleID: "com.apple.Terminal"))
    }
}
