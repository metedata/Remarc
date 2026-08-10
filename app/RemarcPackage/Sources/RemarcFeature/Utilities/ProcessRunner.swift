import Foundation

/// Shared `Process` + `Pipe` helper. Replaces the private `runProcess` helper
/// that used to live inside `MCPManager.swift`, plus a new capturing variant
/// for parsing CLI output (used by `PluginInstallDetector` and `LegacyInstallCleanup`).
public enum ProcessRunner {
    /// Run a process and return `true` on exit-0. Stdout/stderr are discarded.
    @discardableResult
    public static func run(_ executablePath: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// Exit status plus merged stdout+stderr, for callers that need to show
    /// the failure text to the user rather than just detect failure.
    public struct CommandResult: Equatable, Sendable {
        public let exitCode: Int32
        public let output: String
        public let timedOut: Bool

        public init(exitCode: Int32, output: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.output = output
            self.timedOut = timedOut
        }
    }

    /// Like `runCapture`, but returns the result even on nonzero exit, with
    /// stderr merged into the output by default (CLI tools print their errors
    /// there). Pass `mergeStderr: false` when the output will be parsed as
    /// JSON - a stray warning on stderr must not corrupt the payload.
    /// Returns `nil` only when the process could not be launched at all.
    public static func runCollectingResult(_ executablePath: String, arguments: [String], timeoutSeconds: Double, mergeStderr: Bool = true) async -> CommandResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult?, Never>) in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = mergeStderr ? pipe : FileHandle.nullDevice

            let lock = NSLock()
            nonisolated(unsafe) var collected = Data()
            nonisolated(unsafe) var didTimeOut = false
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                collected.append(chunk)
                lock.unlock()
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard process.isRunning else { return }
                lock.withLock { didTimeOut = true }
                process.terminate()
                // Escalate: a process that traps or ignores SIGTERM would
                // otherwise never fire terminationHandler and the caller
                // would hang forever.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                timeoutTask.cancel()
                let timedOutNow = lock.withLock { didTimeOut }
                // Skip the final drain after a timeout: a grandchild that
                // inherited the pipe can keep it open past our SIGKILL of the
                // direct child, and availableData would block on it. Output
                // is not meaningful for a timed-out run anyway.
                if !timedOutNow {
                    let tail = handle.availableData
                    if !tail.isEmpty {
                        lock.withLock { collected.append(tail) }
                    }
                }
                let (snapshot, timedOut) = lock.withLock { (collected, didTimeOut) }

                continuation.resume(returning: CommandResult(
                    exitCode: proc.terminationStatus,
                    output: String(decoding: snapshot, as: UTF8.self),
                    timedOut: timedOut
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Run a process, capture stdout as a UTF-8 string.
    ///
    /// Returns `nil` on timeout, nonzero exit, launch failure, or non-UTF-8
    /// output. Empty string is reserved for the legitimate case where the
    /// command ran successfully and produced no output — distinguishing these
    /// two outcomes matters for callers that gate behavior on the captured
    /// content (e.g., `LegacyInstallCleanup` needs to retry next launch if
    /// the `claude mcp list` call itself failed, not assume "clean").
    public static func runCapture(_ executablePath: String, arguments: [String], timeoutSeconds: Double) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            // The pipe's readabilityHandler fires on a background queue while
            // terminationHandler fires when the process exits. Both touch
            // `collected`. Without a lock this is a data race (caught by Swift 6
            // strict concurrency).
            let lock = NSLock()
            nonisolated(unsafe) var collected = Data()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                collected.append(chunk)
                lock.unlock()
            }

            // Timeout watchdog. terminate() is a no-op if the process already exited.
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                timeoutTask.cancel()
                // Final drain — anything written between the last readability
                // tick and the process exit. availableData returns immediately
                // when the pipe is at EOF, so this is bounded.
                let tail = handle.availableData
                lock.lock()
                if !tail.isEmpty { collected.append(tail) }
                let snapshot = collected
                lock.unlock()

                if proc.terminationStatus == 0,
                   let s = String(data: snapshot, encoding: .utf8) {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}
