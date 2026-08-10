import SwiftUI
import AppKit

struct OnboardingContentView: View {
    @EnvironmentObject var controller: OnboardingWindowController
    @Environment(\.colorScheme) var colorScheme
    @State private var isContinueHovered = false
    @State private var pluginRowState: PluginRowState = .checking

    private enum PluginRowState: Equatable {
        case checking
        case notInstalled
        case installing
        case installed
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            appIcon
                .padding(.bottom, 16)

            welcomeText
                .padding(.bottom, 28)

            permissionRows
                .padding(.horizontal, 40)

            continueButton
                .padding(.top, 24)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(
            width: AppConstants.onboardingWindowWidth,
            height: AppConstants.onboardingWindowHeight
        )
        .background(.regularMaterial)
    }

    // MARK: - App Icon

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 80, height: 80)
        } else {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
                .frame(width: 80, height: 80)
        }
    }

    // MARK: - Welcome Text

    private var welcomeText: some View {
        VStack(spacing: 8) {
            Text("Welcome to Remarc!")
                .font(.system(size: 24, weight: .bold))

            Text("A few permissions are needed to get started.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Permission Rows

    private var permissionRows: some View {
        VStack(spacing: 10) {
            permissionRow(
                icon: "hand.raised.fill",
                title: "Accessibility",
                description: "Remarc reads your selected text so it can attach comments to it.",
                state: controller.accessibilityState,
                action: { controller.requestAccessibility() }
            )

            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                description: "Used for voice dictation and speaking your comments hands-free.",
                state: controller.microphoneState,
                action: { controller.requestMicrophone() }
            )

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "Used to capture screenshots of selected regions alongside your comments.",
                state: controller.screenRecordingState,
                action: { controller.requestScreenRecording() }
            )

            pluginRow
        }
        .task {
            let state = await PluginInstallDetector().read()
            if pluginRowState == .checking {
                pluginRowState = Self.rowState(for: state)
            }
        }
    }

    // MARK: - Claude Code Plugin Row

    /// Same visual grammar as the permission rows, but drives the Claude Code
    /// plugin install (via the claude CLI) instead of a TCC prompt. Not part
    /// of the Continue gate - the plugin is optional and also installable
    /// later from Preferences > MCP Integrations.
    private var pluginRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18))
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code plugin")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text("Manage Remarc comments from Claude Code. Optional - also available later in Preferences.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            pluginStatusButton
                .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: colorScheme == .dark ? 1.0 : 0.0).opacity(0.015))
        )
    }

    @ViewBuilder
    private var pluginStatusButton: some View {
        switch pluginRowState {
        case .checking:
            ProgressView()
                .scaleEffect(0.55)

        case .notInstalled:
            AllowButton(colorScheme: colorScheme, title: "Install", action: installPlugin)
                .help("Runs claude plugin marketplace add + claude plugin install")

        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.55)
                Text("Installing...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

        case .installed:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text("Installed")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(Color.remarcSuccess(for: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.remarcSuccess(for: colorScheme).opacity(0.15))
            )

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color.remarcWarning(for: colorScheme))
                    .help(message)
                AllowButton(colorScheme: colorScheme, title: "Retry", action: installPlugin)
            }
        }
    }

    private static func rowState(for state: PluginInstallState) -> PluginRowState {
        if state.remarcInstalled && state.remarcEnabled { return .installed }
        if state.remarcInstalled {
            return .failed("The remarc plugin is installed but disabled. Run /plugin in Claude Code to enable it.")
        }
        return .notInstalled
    }

    private func installPlugin() {
        pluginRowState = .installing
        Task { @MainActor in
            let outcome = await PluginInstaller.install(plugin: "remarc")
            let state = await PluginInstallDetector().read()
            if state.remarcInstalled {
                pluginRowState = Self.rowState(for: state)
            } else {
                switch outcome {
                case .claudeNotFound:
                    pluginRowState = .failed("Claude Code CLI not found. You can install the plugin later from Preferences > MCP Integrations.")
                case .failed(let message):
                    pluginRowState = .failed(message)
                case .success:
                    // The CLI reported success but verification could not see
                    // it yet (transient list failure). Trust the installer
                    // rather than inviting a duplicate install attempt.
                    pluginRowState = .installed
                }
            }
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        state: PermissionRowState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            permissionStatusButton(state: state, action: action)
                .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: colorScheme == .dark ? 1.0 : 0.0).opacity(0.015))
        )
    }

    @ViewBuilder
    private func permissionStatusButton(
        state: PermissionRowState,
        action: @escaping () -> Void
    ) -> some View {
        switch state {
        case .needsPermission:
            AllowButton(colorScheme: colorScheme, action: action)

        case .waitingForGrant:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.55)
                Text("Waiting...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

        case .granted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text("Enabled")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(Color.remarcSuccess(for: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.remarcSuccess(for: colorScheme).opacity(0.15))
            )
        }
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        let enabled = controller.allPermissionsGranted

        return Button(action: { controller.continueFromOnboarding() }) {
            Text("Continue")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(enabled ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(
                            enabled
                                ? AnyShapeStyle(Color.remarcBrandGradient(for: colorScheme))
                                : AnyShapeStyle(Color.primary.opacity(0.08))
                        )
                )
                .shadow(
                    color: enabled
                        ? Color.remarcPrimary(for: colorScheme).opacity(isContinueHovered ? 0.45 : 0.25)
                        : .clear,
                    radius: isContinueHovered ? 8 : 5,
                    y: 2
                )
                .scaleEffect(enabled && isContinueHovered ? 1.02 : 1.0)
                .opacity(enabled ? (isContinueHovered ? 1.0 : 0.88) : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isContinueHovered = hovering
            }
        }
    }
}

// MARK: - Allow Button

private struct AllowButton: View {
    let colorScheme: ColorScheme
    var title: String = "Allow"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.25 : 0.15))
                )
                .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
