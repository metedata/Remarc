import Foundation
import XCTest

final class PermissionOnboardingContractTests: XCTestCase {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    func testRelocationFinishesBeforeAppSetupStarts() throws {
        let source = try read("app/Remarc/RemarcApp.swift")

        XCTAssertTrue(source.contains("func applicationWillFinishLaunching"))
        XCTAssertTrue(source.contains("let moveStarted = AppMover.moveIfNecessary()"))
        XCTAssertTrue(source.contains("let installedCopyIsAlreadyRunning = installedRemarcCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("shouldSkipSetup = moveStarted || installedCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("guard !Self.isInApplicationsDirectory(Bundle.main.bundleURL)"))
        XCTAssertTrue(source.contains("application.processIdentifier != currentProcessIdentifier"))
        XCTAssertTrue(source.contains("return Self.isInApplicationsDirectory(bundleURL)"))
        XCTAssertTrue(source.contains("if !moveStarted && installedCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
        XCTAssertTrue(source.contains("guard !shouldSkipSetup else { return }"))

        let move = try XCTUnwrap(source.range(of: "AppMover.moveIfNecessary()"))
        let setup = try XCTUnwrap(source.range(of: "AppController.shared.setup()"))
        XCTAssertLessThan(move.lowerBound, setup.lowerBound)
    }

    func testAccessibilityRequestPromptsAndHasSettingsFallback() throws {
        let controller = try read(
            "app/RemarcPackage/Sources/RemarcFeature/Views/OnboardingWindowController.swift"
        )
        let content = try read(
            "app/RemarcPackage/Sources/RemarcFeature/Views/OnboardingContentView.swift"
        )

        XCTAssertTrue(controller.contains("AXIsProcessTrustedWithOptions(options)"))
        XCTAssertTrue(controller.contains("kAXTrustedCheckOptionPrompt"))
        XCTAssertTrue(controller.contains("public func openAccessibilitySettings()"))
        XCTAssertTrue(content.contains("waitingAction: { controller.openAccessibilitySettings() }"))
        XCTAssertTrue(content.contains("Text(\"Open Settings\")"))
    }

    func testScreenRecordingUsesSystemRequestAndShipsPurposeString() throws {
        let controller = try read(
            "app/RemarcPackage/Sources/RemarcFeature/Views/ScreenRecordingPermissionController.swift"
        )
        let onboarding = try read(
            "app/RemarcPackage/Sources/RemarcFeature/Views/OnboardingWindowController.swift"
        )
        let infoPlist = try read("app/Remarc/Info.plist")

        XCTAssertTrue(controller.contains("CGRequestScreenCaptureAccess()"))
        XCTAssertTrue(controller.contains("public func openSystemSettingsPane()"))
        XCTAssertTrue(controller.contains("Button(action: { controller.openSystemSettingsPane() })"))
        XCTAssertTrue(onboarding.contains("permissionController.requestSystemPermission()"))
        XCTAssertTrue(infoPlist.contains("<key>NSScreenCaptureUsageDescription</key>"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
