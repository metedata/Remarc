import Testing
@testable import RemarcFeature

@Suite("Selection UI policy")
struct SelectionUIPolicyTests {
    @Test("Auto mode shows selection UI when not paused")
    func autoModeShowsUI() {
        #expect(SelectionUIPolicy.shouldShowSelectionUI(isPaused: false, mode: .auto))
    }

    @Test("Hotkey Only hides selection UI")
    func hotkeyOnlyHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: false, mode: .hotkeyOnly))
    }

    @Test("Pausing hides selection UI even in auto mode")
    func pausedHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: true, mode: .auto))
    }

    @Test("Pausing and Hotkey Only together still hide selection UI")
    func pausedHotkeyOnlyHidesUI() {
        #expect(!SelectionUIPolicy.shouldShowSelectionUI(isPaused: true, mode: .hotkeyOnly))
    }
}
