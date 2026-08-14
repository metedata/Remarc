import Foundation
import Darwin

/// Decides whether pressing the wake button could actually reach an agent.
///
/// Plugin-install state is the wrong signal: it does not say which harness the
/// user is working in right now, or whether that process owns a live pairing.
///
/// The sessions themselves are the authority. Each paired integration writes
/// a marker saying whether it can be woken, so this just asks: is any
/// wake-capable session currently alive?
enum WakeReachability {
    /// A session that has shown no activity for this long is treated as gone.
    /// Markers are also removed at SessionEnd; this covers abnormal exits.
    private static let liveWindow: TimeInterval = 60 * 60 * 4

    static var markersDirectory: URL {
        // `claude` is a historical path component retained as the shared
        // cross-harness marker contract.
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remarc/claude/markers", isDirectory: true)
    }

    /// Markers are written by Node, whose `Date.toISOString()` always emits
    /// milliseconds. `ISO8601DateFormatter` parses exactly one shape per
    /// configuration and returns nil for the other, so both are needed: the
    /// fractional one for every marker written today, the plain one for markers
    /// left by builds that predate millisecond precision.
    /// Built per call rather than cached: `ISO8601DateFormatter` is not
    /// `Sendable`, and this runs a handful of times when the composer opens.
    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// True when at least one live session declared itself wake-capable.
    ///
    /// Cheap enough to call whenever the composer opens: a directory listing
    /// and a few small JSON reads, no subprocess.
    ///
    /// `directory` exists so tests can point at a temp directory. Reading the
    /// real one would make them depend on whichever agent sessions happen to be
    /// running on the machine.
    static func anyWakeCapableSessionIsLive(
        in directory: URL? = nil,
        now: Date = .now,
        processIsLive: (Int32) -> Bool = defaultProcessIsLive
    ) -> Bool {
        liveWakeCapableSessionExists(
            pairedTo: nil,
            in: directory,
            now: now,
            processIsLive: processIsLive
        )
    }

    /// True when the agent paired with `remarcSessionID` is live and wakeable.
    ///
    /// Wake targets exactly one agent: the one paired with the session the
    /// comment is filed to. Matching on wake state alone woke every live agent
    /// on the machine, each spending context on the same comment before the
    /// compare-and-set claim picked a single winner.
    ///
    /// Pass `nil` to ask whether any paired agent is live at all, which is what
    /// Preferences reports.
    static func liveWakeCapableSessionExists(
        pairedTo remarcSessionID: UUID?,
        in directory: URL? = nil,
        now: Date = .now,
        processIsLive: (Int32) -> Bool = defaultProcessIsLive
    ) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory ?? markersDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }

        let wanted = remarcSessionID?.uuidString.uppercased()

        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  exactBoolean(raw["wakeCapable"]) == true
            else { continue }

            // An agent with no paired session is not a wake target, so it is
            // not evidence of reachability either - it cannot be sent anything.
            guard let paired = raw["remarcSessionId"] as? String, !paired.isEmpty
            else { continue }
            if let wanted, paired.uppercased() != wanted { continue }

            if isLive(raw: raw, now: now, processIsLive: processIsLive) { return true }
        }
        return false
    }

    private static func isLive(
        raw: [String: Any],
        now: Date,
        processIsLive: (Int32) -> Bool
    ) -> Bool {
        let hasVersionedLeaseField = [
            "protocolVersion", "ownerPid", "ownerToken", "leaseHeartbeatAt",
        ].contains { raw[$0] != nil }

        if let harnessValue = raw["harness"] {
            guard let harness = harnessValue as? String else { return false }
            switch harness {
            case "omp":
                return isLiveOMPLease(raw: raw, now: now, processIsLive: processIsLive)
            case "claudeCode":
                if hasVersionedLeaseField { return false }
                break
            default:
                return false
            }
        } else if hasVersionedLeaseField {
            // A partially written or damaged OMP lease must fail closed. The
            // extension also refreshes lastActivity, so treating this as a
            // historical Claude marker would keep a dead owner reachable for
            // the four-hour legacy window.
            return false
        }

        // A named transcript settles it on its own, present or absent.
        //
        // Absent is the interesting case. `claude plugin list --json` - which
        // this app runs itself, at launch and from Preferences, to detect the
        // plugin - fires SessionStart like any other session. The hook dutifully
        // writes a wake-capable marker naming a transcript that the invocation
        // exits too fast to ever create. Falling through to `lastActivity` then
        // read that marker as live, so the app manufactured its own evidence
        // that a wakeable session existed and showed a button wired to nothing.
        //
        // A real session's transcript exists by the time anything asks.
        if let path = raw["transcriptPath"] as? String, !path.isEmpty {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date
            else { return false }
            return now.timeIntervalSince(modified) < liveWindow
        }
        if let activity = raw["lastActivity"] as? String,
           let date = parseTimestamp(activity) {
            return now.timeIntervalSince(date) < liveWindow
        }
        // Deliberately no fall back to the marker file's own mtime. Every
        // integration that writes a legacy marker also stamps `lastActivity`, so a marker without
        // one is not evidence of anything - and the mtime is rewritten on every
        // delivery, which made it read as "live" unconditionally. That fallback
        // is what hid the timestamps above going unparsed for every real marker.
        return false
    }

    /// OMP runs extensions in-process, so a marker needs both a live process
    /// identity and a recently renewed token-owned lease. Neither signal is
    /// sufficient alone: PID reuse makes process-only checks stale, while a
    /// heartbeat without a process can outlive a crash.
    private static func isLiveOMPLease(
        raw: [String: Any],
        now: Date,
        processIsLive: (Int32) -> Bool
    ) -> Bool {
        guard exactInteger(raw["protocolVersion"]) == 1,
              let token = raw["ownerToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ownerPID = exactInteger(raw["ownerPid"]),
              ownerPID > 0,
              ownerPID <= Int(Int32.max),
              processIsLive(Int32(ownerPID)),
              let heartbeatValue = raw["leaseHeartbeatAt"] as? String,
              let heartbeat = parseTimestamp(heartbeatValue)
        else { return false }

        let age = now.timeIntervalSince(heartbeat)
        return (-30 ... 60).contains(age)
    }

    /// `JSONSerialization` represents both booleans and numbers as NSNumber,
    /// so parse through the Objective-C type marker and require an exact,
    /// finite integer rather than accepting `true`, `1.5`, or an overflow.
    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }

        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }

    private static func exactBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func defaultProcessIsLive(_ pid: Int32) -> Bool {
        errno = 0
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
