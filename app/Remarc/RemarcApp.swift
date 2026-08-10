import SwiftUI
import AppKit
import RemarcFeature
import AppMover

@main
struct RemarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    Task { @MainActor in
                        PreferencesWindowController.shared.show()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        AppMover.moveIfNecessary()
        #endif

        AppController.shared.setup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppController.shared.handleDockIconClick()
        }
        return false
    }
}
