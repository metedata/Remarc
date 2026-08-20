/// Whether selection-driven UI (the tooltip) should appear for a detected selection.
///
/// `SelectionMonitor` keeps running in `.hotkeyOnly` because the hotkey's own
/// fresh-read fallback is the weaker path (see `SelectionMonitor.readCurrentSelection`),
/// and because the PopClip URL path depends on the monitor's stashed selection.
/// So the mode is enforced here, at the point of display, not at the monitor.
public enum SelectionUIPolicy {
    public static func shouldShowSelectionUI(
        isPaused: Bool,
        mode: SettingsManager.SelectionDetectionMode
    ) -> Bool {
        !isPaused && mode == .auto
    }
}
