import Foundation

/// A PNG that has been written to disk but is not yet referenced by any comment.
///
/// The capture transaction writes the image before it creates the comment, so
/// there is always a window in which the file is real and unreferenced. If the
/// process dies inside that window the file would leak forever.
public struct PreparedCaptureLease: Codable, Equatable, Sendable {
    /// Relative to the Remarc App Support directory, e.g. `images/UUID.png`.
    public let path: String
    public let pid: Int32
    /// Boot time of the machine that recorded this. A PID from a previous boot
    /// says nothing about the PID running now.
    public let bootTime: Int64
    /// Start time of that PID, so a recycled PID is distinguishable from the
    /// original owner still running.
    public let startTime: Int64
    public let at: Double

    public init(path: String, pid: Int32, bootTime: Int64, startTime: Int64, at: Double) {
        self.path = path
        self.pid = pid
        self.bootTime = bootTime
        self.startTime = startTime
        self.at = at
    }
}

/// Crash reconciliation for prepared-but-unreferenced capture PNGs.
///
/// This is deliberately NOT a directory sweep. Remarc keeps two kinds of image on
/// disk that no comment references and that a sweep would destroy:
///
///  - images of pruned comments, retained in `appState.orphanedImages` until a
///    separate image-retention cutoff (`PersistenceManager.pruneExpiredHistory`)
///  - attachments, which are written before any comment references them and can
///    sit draft-held indefinitely (`CommentInputView`)
///
/// So only paths this registry recorded are ever considered, and the images
/// directory is never enumerated.
public enum PreparedCaptureLeaseRegistry {

    public static var registryURL: URL {
        remarcAppSupportURL
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(".prepared-leases.json")
    }

    // MARK: - Owner identity

    /// Seconds since the epoch at which this machine booted.
    public static func currentBootTime() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int64(tv.tv_sec)
    }

    /// Microseconds since the epoch at which `pid` started, or nil when no such
    /// process exists.
    public static func processStartTime(pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    /// A lease whose owner is confirmed gone.
    ///
    /// Age alone never reclaims. A timestamp cutoff elapses while a process is
    /// merely suspended or slow, and reclaiming a live transaction's PNG means
    /// deleting a file the original process is about to reference from a comment.
    /// `DocumentLock`'s own reclaim does treat age independently of liveness,
    /// which is tolerable for a lock and not for a file a comment will point at.
    public static func isAbandoned(_ lease: PreparedCaptureLease,
                                   bootTime: Int64 = currentBootTime()) -> Bool {
        // A different boot means every recorded PID is meaningless.
        if lease.bootTime != bootTime { return true }
        guard let start = processStartTime(pid: lease.pid) else { return true }
        // Live PID, but started at a different time: the number was recycled.
        return start != lease.startTime
    }

    // MARK: - Path validation

    /// True when `relativePath` resolves to a direct child of `Remarc/images`
    /// with the generated UUID-PNG filename shape.
    ///
    /// `resolveImagePath` appends whatever components it is handed, so a corrupt
    /// or hand-edited registry could otherwise aim a delete anywhere on disk.
    public static func isDeletableImagePath(_ relativePath: String) -> Bool {
        let imagesDir = remarcAppSupportURL
            .appendingPathComponent("images", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolveImagePath(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()

        guard candidate.deletingLastPathComponent().path == imagesDir.path else { return false }
        let name = candidate.lastPathComponent
        guard name.lowercased().hasSuffix(".png") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    // MARK: - Registry I/O

    /// Every read-modify-write happens under `DocumentLock` keyed on the registry
    /// file itself. `DocumentLock` locks the URL it is handed, so naming the
    /// target explicitly is what makes this atomic across instances.
    private static func mutate<T>(_ body: (inout [PreparedCaptureLease]) -> T) throws -> T {
        let url = registryURL
        return try DocumentLock.withLock(url) {
            var leases = readUnlocked(url)
            let result = body(&leases)
            try writeUnlocked(leases, to: url)
            return result
        }
    }

    private static func readUnlocked(_ url: URL) -> [PreparedCaptureLease] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PreparedCaptureLease].self, from: data)
        else { return [] }
        return decoded
    }

    private static func writeUnlocked(_ leases: [PreparedCaptureLease], to url: URL) throws {
        if leases.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(leases)
        try data.write(to: url, options: .atomic)
    }

    /// Record ownership of `relativePath` before the PNG is written.
    public static func record(path relativePath: String) throws {
        let lease = PreparedCaptureLease(
            path: relativePath,
            pid: ProcessInfo.processInfo.processIdentifier,
            bootTime: currentBootTime(),
            startTime: processStartTime(pid: ProcessInfo.processInfo.processIdentifier) ?? 0,
            at: Date().timeIntervalSince1970
        )
        try mutate { $0.removeAll { $0.path == relativePath }; $0.append(lease) }
    }

    /// Release ownership. Called by exactly one of finalize or restore.
    public static func release(path relativePath: String) throws {
        try mutate { $0.removeAll { $0.path == relativePath } }
    }

    public static func currentLeases() -> [PreparedCaptureLease] {
        (try? DocumentLock.withLock(registryURL) { readUnlocked(registryURL) }) ?? []
    }

    // MARK: - Startup reconciliation

    public struct ReconcileResult: Equatable, Sendable {
        public var deleted: [String] = []
        public var keptLive: [String] = []
        public var keptReferenced: [String] = []
        public var rejectedPath: [String] = []
    }

    /// Drop leases whose owner is confirmed gone, deleting the PNG only when
    /// nothing references it.
    ///
    /// `isReferenced` must consider soft-deleted comments, attachments, and
    /// `orphanedImages`, because all three are references the user still depends
    /// on. Anything not in the registry is never touched.
    @discardableResult
    public static func reconcile(isReferenced: (String) -> Bool) -> ReconcileResult {
        var result = ReconcileResult()
        let boot = currentBootTime()

        let outcome = try? mutate { leases -> ReconcileResult in
            var survivors: [PreparedCaptureLease] = []
            for lease in leases {
                guard isAbandoned(lease, bootTime: boot) else {
                    result.keptLive.append(lease.path)
                    survivors.append(lease)
                    continue
                }
                if isReferenced(lease.path) {
                    // The owner died after the comment landed. The file is real
                    // and referenced; only the bookkeeping is stale.
                    result.keptReferenced.append(lease.path)
                    continue
                }
                guard isDeletableImagePath(lease.path) else {
                    result.rejectedPath.append(lease.path)
                    continue
                }
                // The whole family, not just the PNG. A prepared capture should
                // never have sidecars - annotation happens on committed comments
                // - but this sweep exists to reclaim files nothing references,
                // and leaving a base behind would defeat exactly that.
                try? AnnotationMarkStore.deleteImageFamily(lease.path)
                result.deleted.append(lease.path)
            }
            leases = survivors
            return result
        }
        return outcome ?? result
    }
}
