import Foundation
import Sparkle

@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController!

    @Published public private(set) var canCheckForUpdates: Bool = false

    private override init() {
        super.init()

        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            UserDefaults.standard.set(true, forKey: "SUEnableAutomaticChecks")
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupObservers()
        debugLog("UpdateManager initialized")
    }

    private func setupObservers() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    public func checkForUpdates() {
        debugLog("Manual update check triggered")
        updaterController.checkForUpdates(nil)
    }
}
