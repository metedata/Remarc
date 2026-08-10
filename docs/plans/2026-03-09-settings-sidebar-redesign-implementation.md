# Settings Sidebar Redesign — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the toolbar-tab settings window with a sidebar-navigated layout, reorganize settings into 8 focused sections, inline the excluded apps list, and add an About section.

**Architecture:** `NavigationSplitView` with a flat sidebar (200pt) and detail pane (~900pt). Each sidebar row maps to a `SettingsSection` enum case. Detail panes are extracted into separate views. The window widens from 980 to 1100pt.

**Tech Stack:** SwiftUI, AppKit (NSWindow, NSOpenPanel), KeyboardShortcuts, Sparkle (UpdateManager)

**Design doc:** `docs/plans/2026-03-09-settings-sidebar-redesign.md`

---

### Task 1: Scaffold SettingsSection enum and NavigationSplitView skeleton

Replace the `PrefsTab` enum and `TabView` with the new sidebar structure. No detail pane content yet — just the navigation shell.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift:46-97` (PreferencesView)

**Step 1: Replace PrefsTab enum with SettingsSection**

Replace lines 54-70 (the `PrefsTab` enum) with:

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case export = "Export"
    case chromeExtension = "Chrome Extension"
    case mcpServer = "MCP Server"
    case excludedApps = "Excluded Apps"
    case license = "License"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .export: return "square.and.arrow.up"
        case .chromeExtension: return "globe"
        case .mcpServer: return "server.rack"
        case .excludedApps: return "app.dashed"
        case .license: return "key"
        case .about: return "info.circle"
        }
    }
}
```

**Step 2: Replace TabView body with NavigationSplitView**

Replace the `body` (lines 72-97) with:

```swift
var body: some View {
    NavigationSplitView {
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .navigationSplitViewColumnWidth(200)
        .listStyle(.sidebar)
    } detail: {
        Group {
            switch selectedSection {
            case .general: Text("General — TODO")
            case .shortcuts: Text("Shortcuts — TODO")
            case .export: exportTab
            case .chromeExtension: chromeExtensionTab
            case .mcpServer: Text("MCP Server — TODO")
            case .excludedApps: Text("Excluded Apps — TODO")
            case .license: licenseTab
            case .about: Text("About — TODO")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onReceive(NotificationCenter.default.publisher(for: PreferencesWindowController.selectTabNotification)) { notification in
        if let raw = notification.object as? String,
           let section = SettingsSection(rawValue: raw) {
            selectedSection = section
        }
    }
}
```

Update the `@State` property (line 50):
```swift
@State private var selectedSection: SettingsSection = .general
```

**Step 3: Update PreferencesWindowController window size**

In `createWindow()` (line 30), change the contentRect:
```swift
contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500),
```

Change the window title (line 36):
```swift
window.title = "Remarc Settings"
```

**Step 4: Update show(tab:) to use SettingsSection**

Update the `show(tab:)` method — no signature change needed since it still takes a String that maps to `SettingsSection.rawValue`. But update the caller in `WebSocketService.swift:232` from `"Extension"` to `"Chrome Extension"`.

**Step 5: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git add app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift
git commit -m "refactor: replace toolbar tabs with NavigationSplitView sidebar"
```

---

### Task 2: Extract General detail pane

Move the general settings into a reorganized General detail pane with grouped form sections (App, Clipboard, Retention).

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Create generalSection computed property**

Replace the existing `generalTab` (lines 116-280) with a new `generalSection` that uses the existing helper methods (`sectionHeader`, `settingsRow`, `toggleRow`, `pickerRow`). Organize into three visual groups:

```swift
private var generalSection: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            // App section
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader("App", description: "Startup and detection behavior.")
                toggleRow("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                pickerRow("Detection mode", selection: $settings.selectionDetectionMode) { $0.label }
            }

            Divider()

            // Clipboard section
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader("Clipboard", description: "How copied content is processed.")
                toggleRow("Clean up whitespace", isOn: $settings.normalizeWhitespace)
                toggleRow("Copy screenshot", isOn: $settings.copyScreenshotToClipboard)
            }

            Divider()

            // Retention section
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader("Retention", description: "How long comments and images are kept.")
                settingsRow("History retention") {
                    RemarcDropdown(
                        selection: $settings.historyRetentionDays,
                        options: [1, 7, 30],
                        labelFor: { days in
                            switch days {
                            case 1: return "1 day"
                            case 7: return "1 week"
                            case 30: return "1 month"
                            default: return "\(days) days"
                            }
                        },
                        width: Self.pickerWidth
                    )
                }
                settingsRow("Image retention") {
                    RemarcDropdown(
                        selection: $settings.imageRetentionDays,
                        options: [7, 14, 30],
                        labelFor: { days in
                            switch days {
                            case 7: return "1 week"
                            case 14: return "2 weeks"
                            case 30: return "1 month"
                            default: return "\(days) days"
                            }
                        },
                        width: Self.pickerWidth
                    )
                }
                Text("Images are kept longer so exported references stay valid.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                pickerRow("Delete resolved", selection: $settings.resolvedCommentDeletion) { $0.label }

                Divider()

                HStack {
                    Text("Total remarks")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.6))
                    Spacer()
                    Text("\(PersistenceManager.shared.appState.totalCommentsCreated)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.45))
                }
            }
        }
        .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}
```

**Step 2: Wire into NavigationSplitView**

Replace `Text("General — TODO")` with `generalSection`.

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add General detail pane with grouped sections"
```

---

### Task 3: Extract Shortcuts detail pane

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Create shortcutsSection computed property**

```swift
private var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: Self.itemSpacing) {
        sectionHeader("Shortcuts", description: "Global keyboard shortcuts for Remarc actions.")

        settingsRow("Comment") {
            KeyboardShortcuts.Recorder("", name: .commentOnSelection)
        }
        settingsRow("Screenshot") {
            KeyboardShortcuts.Recorder("", name: .screenshotComment)
        }
        settingsRow("Paste All") {
            KeyboardShortcuts.Recorder("", name: .pasteAllComments)
        }
        if #available(macOS 26, *) {
            settingsRow("Voice Input") {
                KeyboardShortcuts.Recorder("", name: .voiceInput)
            }
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}
```

**Step 2: Wire into NavigationSplitView**

Replace `Text("Shortcuts — TODO")` with `shortcutsSection`.

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add Shortcuts detail pane"
```

---

### Task 4: Extract MCP Server detail pane

Move the MCP Server settings out of the old `generalTab` into its own section.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Create mcpServerSection computed property**

```swift
private var mcpServerSection: some View {
    VStack(alignment: .leading, spacing: Self.itemSpacing) {
        sectionHeader("MCP Server", description: "AI coding tool integration via Model Context Protocol.")

        toggleRow("Enable MCP server", isOn: Binding(
            get: { mcpManager.isEnabled },
            set: { newValue in
                Task {
                    if newValue {
                        await mcpManager.enable()
                        showMCPRelaunchHint = true
                    } else {
                        await mcpManager.disable()
                        showMCPRelaunchHint = false
                    }
                }
            }
        ), disabled: mcpManager.nodeStatus == .notFound || mcpManager.claudeStatus == .notFound)

        if showMCPRelaunchHint {
            HStack(spacing: 4) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 11))
                Text("Relaunch your AI agent to connect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }

        if mcpManager.nodeStatus == .notFound {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text("Node.js required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }

        if mcpManager.claudeStatus == .notFound {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text("Claude Code CLI required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }

        if mcpManager.nodeStatus == .notFound || mcpManager.claudeStatus == .notFound {
            Button("Check Again") {
                mcpManager.checkDependencies()
            }
            .font(.system(size: 11))
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { mcpManager.checkDependencies() }
}
```

**Step 2: Wire into NavigationSplitView**

Replace `Text("MCP Server — TODO")` with `mcpServerSection`.

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add MCP Server detail pane"
```

---

### Task 5: Inline Excluded Apps with NSOpenPanel

Replace the button-that-opens-a-window with an inline editable list using the standard macOS +/- pattern.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Views/ExcludeListWindowController.swift` (after migration)

**Step 1: Create ExcludedAppInfo struct and excludedAppsSection**

Add a struct for display data and the detail pane. The + button uses `NSOpenPanel` filtered to `.app` bundles:

```swift
private struct ExcludedAppInfo: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }
}
```

```swift
@State private var excludedApps: [ExcludedAppInfo] = []
@State private var excludedSelection: Set<String> = []

private var excludedAppsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        sectionHeader(
            "Excluded Apps",
            description: "Remarc won't show the comment tooltip in these apps."
        )

        // App list
        List(excludedApps, selection: $excludedSelection) { app in
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text(app.name)
                    .font(.system(size: 13))
                Spacer()
                Text(app.bundleID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.35))
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 200)
        .overlay {
            if excludedApps.isEmpty {
                VStack(spacing: 4) {
                    Text("No excluded apps")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.4))
                    Text("Click + to add an application.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.3))
                }
            }
        }

        // +/- buttons
        HStack(spacing: 8) {
            Button(action: addExcludedApp) {
                Image(systemName: "plus")
            }
            .help("Add application")

            Button(action: removeSelectedApps) {
                Image(systemName: "minus")
            }
            .disabled(excludedSelection.isEmpty)
            .help("Remove selected")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { loadExcludedApps() }
}

private func addExcludedApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = "Select applications to exclude"
    panel.begin { response in
        guard response == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { continue }
            if !settings.excludedAppBundleIDs.contains(bundleID) {
                settings.excludedAppBundleIDs.append(bundleID)
            }
        }
        loadExcludedApps()
    }
}

private func removeSelectedApps() {
    settings.excludedAppBundleIDs.removeAll { excludedSelection.contains($0) }
    excludedSelection.removeAll()
    loadExcludedApps()
}

private func loadExcludedApps() {
    excludedApps = settings.excludedAppBundleIDs.map { bundleID in
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        let name = path.map { FileManager.default.displayName(atPath: $0) } ?? bundleID
        let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
        return ExcludedAppInfo(bundleID: bundleID, name: name, icon: icon)
    }
}
```

**Step 2: Wire into NavigationSplitView**

Replace `Text("Excluded Apps — TODO")` with `excludedAppsSection`.

**Step 3: Remove ExcludeListWindowController**

Delete `app/RemarcPackage/Sources/RemarcFeature/Views/ExcludeListWindowController.swift`.
Remove the import/reference from the old `excludedAppsTab` in PreferencesWindowController.swift (already replaced).

**Step 4: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git rm app/RemarcPackage/Sources/RemarcFeature/Views/ExcludeListWindowController.swift
git commit -m "feat: inline excluded apps with NSOpenPanel add pattern"
```

---

### Task 6: Add About section

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Create aboutSection computed property**

```swift
private var aboutSection: some View {
    VStack(spacing: 16) {
        Spacer()

        // App icon
        if let appIcon = NSApp.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
        }

        // App name
        Text("Remarc")
            .font(.system(size: 24, weight: .semibold))

        // Tagline
        Text("Contextual comments on any text selection")
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(0.6))

        // Version
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            Text("v\(version) (\(build))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.35))
        }

        // Check for Updates
        Button("Check for Updates\u{2026}") {
            UpdateManager.shared.checkForUpdates()
        }
        .disabled(!UpdateManager.shared.canCheckForUpdates)

        // Links
        HStack(spacing: 16) {
            Link("Website", destination: URL(string: "https://remarc.app")!)
            Link("Changelog", destination: URL(string: "https://remarc.app/changelog")!)
            Link("Support", destination: URL(string: "https://remarc.app/support")!)
        }
        .font(.system(size: 12))

        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

**Step 2: Wire into NavigationSplitView**

Replace `Text("About — TODO")` with `aboutSection`.

**Step 3: Add @ObservedObject for UpdateManager**

Add to the PreferencesView properties:
```swift
@ObservedObject private var updateManager = UpdateManager.shared
```

**Step 4: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add About section with version, update check, and links"
```

---

### Task 7: Clean up old code and persist sidebar selection

Remove dead code from the old tab layout and add UserDefaults persistence for the selected sidebar section.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Remove old generalTab, excludedAppsTab computed properties**

Delete the old `generalTab` and `excludedAppsTab` computed properties — their content has been migrated to the new section views. Keep `exportTab`, `chromeExtensionTab`, and `licenseTab` as they were (just rename to `exportSection`, `chromeExtensionSection`, `licenseSection` for consistency).

**Step 2: Remove sectionCard helper**

The `sectionCard` helper (lines 99-114) was used for the grid card layout in the old General tab. It's no longer needed — delete it. Check if `chromeExtensionTab` still uses it; if so, replace with `VStack` + padding or keep until chrome extension layout is updated.

**Step 3: Persist selected section**

Change the `@State` for selectedSection to read/write UserDefaults:

```swift
@State private var selectedSection: SettingsSection = {
    if let raw = UserDefaults.standard.string(forKey: "selectedSettingsSection"),
       let section = SettingsSection(rawValue: raw) {
        return section
    }
    return .general
}()
```

Add an `onChange` to persist:
```swift
.onChange(of: selectedSection) { _, newValue in
    UserDefaults.standard.set(newValue.rawValue, forKey: "selectedSettingsSection")
}
```

**Step 4: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "refactor: clean up old tab code, persist sidebar selection"
```

---

### Task 8: Visual polish pass

Ensure consistent padding, alignment, and spacing across all detail panes.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Audit padding and alignment**

Ensure all detail panes follow the same pattern:
- `.padding(24)` on the outer container
- `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` on non-centered panes
- Section spacing of 24pt between groups, 10pt between items
- Export pane: verify it renders correctly in the wider ~900pt detail area (may need to adjust the left column width from 330pt)

**Step 2: Verify Chrome Extension pane**

The Chrome Extension pane currently uses `sectionCard` for its two-column layout. Decide whether to keep the card styling or switch to the same Divider-separated sections used in General. If `sectionCard` is removed in Task 7, update Chrome Extension to use Divider-separated groups.

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
bash scripts/relaunch.sh
```

**Step 4: Visual verification**

User verifies:
- All 8 sidebar items navigate correctly
- General sections (App, Clipboard, Retention) are visually grouped
- Export preview renders correctly in wider pane
- Excluded Apps shows +/- buttons, NSOpenPanel works
- About shows icon, version, links
- Sidebar selection persists across close/reopen
- Window title shows "Remarc Settings"

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "style: polish settings pane alignment and spacing"
```
