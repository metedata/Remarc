import Foundation

/// Resolves binary paths by trying the user's login shells, then common
/// install directories as a fallback.
///
/// macOS GUI apps inherit launchd's minimal environment. Login shells (`-l`)
/// source `~/.zprofile` but NOT `~/.zshrc`. Tools that add themselves to PATH
/// only via `.zshrc` won't be found by shell resolution alone.
///
/// We avoid `-i` (interactive) shells because oh-my-zsh, powerlevel10k,
/// conda, etc. print init output to stdout that corrupts the `which` result.
enum ShellResolver {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let fallbackDirs = [
        "\(home)/.local/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ]

    static func resolveBinaryPath(_ name: String) async -> String? {
        // 1. Try login shells concurrently, prefer zsh result
        let shells: [(path: String, args: [String])] = [
            ("/bin/zsh", ["-l", "-c", "which \(name)"]),
            ("/bin/bash", ["-l", "-c", "which \(name)"]),
        ]

        let result = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, shell) in shells.enumerated() {
                group.addTask {
                    (index, await runWhich(shell.path, arguments: shell.args))
                }
            }

            var best: (Int, String)? = nil
            for await (index, path) in group {
                guard let path else { continue }
                if best == nil || index < best!.0 {
                    best = (index, path)
                }
            }
            return best?.1
        }
        if let result { return result }

        // 2. Fallback: check common install directories directly
        for dir in fallbackDirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 3. For node specifically, check nvm's current default
        if name == "node", let nvmNode = resolveNvmNode() {
            return nvmNode
        }

        return nil
    }

    /// Finds the node binary from nvm's default alias.
    /// Only resolves numeric aliases (e.g. "20", "20.11.0"); lts/* aliases
    /// are not supported and fall through to nil.
    private static func resolveNvmNode() -> String? {
        let nvmDir = "\(home)/.nvm"
        let aliasPath = "\(nvmDir)/alias/default"
        guard let version = try? String(contentsOf: URL(fileURLWithPath: aliasPath), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        let versionsDir = "\(nvmDir)/versions/node"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else { return nil }

        let match = entries
            .filter { $0 == "v\(version)" || $0.hasPrefix("v\(version).") }
            .sorted()
            .last

        if let match {
            let nodePath = "\(versionsDir)/\(match)/bin/node"
            if FileManager.default.isExecutableFile(atPath: nodePath) {
                return nodePath
            }
        }
        return nil
    }

    private static func runWhich(_ shellPath: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0, let path, !path.isEmpty {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
