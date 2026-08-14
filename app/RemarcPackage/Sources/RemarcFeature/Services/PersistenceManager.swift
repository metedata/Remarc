import Foundation
import Combine
import AppKit

@MainActor
public final class PersistenceManager: ObservableObject {
    public static let shared = PersistenceManager()

    @Published public private(set) var appState: AppState

    private let fileURL: URL
    /// The document as we last read or wrote it. Baseline for the three-way
    /// merge that keeps other processes' commits from being overwritten.
    private var lastPersisted: AppState
    /// Serializes background writes off the main actor (see DocumentWriter).
    private let documentWriter = DocumentWriter()
    private var backgroundSaveInFlight = false
    /// A mutation arrived while a save was in flight; that save's snapshot is
    /// stale, so another must follow it.
    private var backgroundSaveRequested = false
    private var saveCancellable: AnyCancellable?
    private let saveSubject = PassthroughSubject<Void, Never>()
    private var resolvedDeletionTimer: Timer?
    private var resolvedDeletionCancellable: AnyCancellable?
    private var inactiveSessionTimer: Timer?
    private var inactiveSessionCancellable: AnyCancellable?

    // MARK: - Document write serialization
    //
    // `saveToDisk` is synchronous and runs entirely on the main actor, so no two
    // ordinary saves can interleave. A durable write cannot be synchronous - it
    // waits on a cross-process lock that polls with `Thread.sleep` - so it awaits
    // an off-main helper, and that await yields the main actor. Without a gate, a
    // debounced save or a reload adoption could land inside that window and
    // publish state computed from a snapshot older than the durable write's, both
    // clobbering the newer value and regressing `lastPersisted`.
    //
    // The gate is deliberately one flag plus deferrals rather than a general
    // operation queue. Routing the existing synchronous entry points through a
    // queue would make them async, which in turn would force `saveImmediately()`
    // to defer termination via `applicationShouldTerminate` - machinery Remarc
    // does not have today. Leaving them synchronous keeps quit exactly as durable
    // as it already is.

    /// True while a durable write owns the document. Ordinary saves and reloads
    /// arriving in this window record themselves and run once it clears.
    private var documentWriteInFlight = false
    private var deferredSaveRequested = false
    private var deferredReloadRequested = false
    private var documentSlotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Sessions a durable write is currently staging a comment into. Deleting one
    /// mid-transaction would re-apply after validation had already passed,
    /// reproducing the invisible-comment state validation exists to prevent.
    private var pinnedSessionIDs: Set<UUID> = []
    private var deferredSessionDeletions: [UUID] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let remarcDir = appSupport.appendingPathComponent("Remarc", isDirectory: true)

        if !FileManager.default.fileExists(atPath: remarcDir.path) {
            try? FileManager.default.createDirectory(at: remarcDir, withIntermediateDirectories: true)
        }

        // Create images subdirectory for future screenshot support
        let imagesDir = remarcDir.appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: imagesDir.path) {
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // Migrate data.json → comments.json if needed
        let oldFileURL = remarcDir.appendingPathComponent("data.json")
        let newFileURL = remarcDir.appendingPathComponent("comments.json")
        if FileManager.default.fileExists(atPath: oldFileURL.path)
            && !FileManager.default.fileExists(atPath: newFileURL.path) {
            try? FileManager.default.moveItem(at: oldFileURL, to: newFileURL)
            debugLog("PersistenceManager: Migrated data.json → comments.json")
        }

        self.fileURL = newFileURL

        // Load or create default state
        if let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            self.appState = state
            self.lastPersisted = state
            debugLog("PersistenceManager: Loaded \(state.comments.count) comments, \(state.sessions.count) sessions")
        } else {
            self.appState = AppState.defaultState()
            self.lastPersisted = AppState.defaultState()
            debugLog("PersistenceManager: Created default state")
        }

        // Migrate first session to Inbox if needed
        if let firstIndex = appState.sessions.firstIndex(where: { !$0.isDeleted }) {
            if appState.sessions[firstIndex].name != AppConstants.inboxSessionName {
                appState.sessions[firstIndex].name = AppConstants.inboxSessionName
            }
        }

        // Ensure Inbox session always exists (fresh install or all sessions deleted)
        if !appState.sessions.contains(where: { !$0.isDeleted && $0.isInbox }) {
            let inbox = Session(name: AppConstants.inboxSessionName)
            appState.sessions.append(inbox)
            if appState.activeSessionID == nil {
                appState.activeSessionID = inbox.id
            }
            debugLog("PersistenceManager: Created Inbox session")
        }

        // Debounced auto-save (250ms)
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.saveToDisk()
            }

        // Prune expired history on launch
        pruneExpiredHistory()

        // Listen for external reload requests (from MCP server)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.metepolat.Remarc.reload"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromDisk()
        }

        // Auto-delete resolved comments on launch (catches expired while app was closed)
        autoDeleteResolvedComments()

        // Observe setting changes to start/stop the resolved deletion timer
        resolvedDeletionCancellable = SettingsManager.shared.$resolvedCommentDeletion
            .sink { [weak self] setting in
                self?.updateResolvedDeletionTimer(for: setting)
            }

        inactiveSessionCancellable = Publishers.CombineLatest(
            SettingsManager.shared.$inactiveSessionCleanupEnabled,
            SettingsManager.shared.$inactiveSessionCleanupInterval
        )
        .sink { [weak self] _, _ in self?.updateInactiveSessionTimer() }

        cleanupStaleClaudeCodeMarkers()

        reconcilePreparedCaptureLeases()

        // Ensure the data file exists on disk (bootstraps comments.json on fresh installs
        // so the CLI/hooks can read it immediately)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            saveToDisk()
        }
    }

    // MARK: - Session Operations

    public var activeSession: Session? {
        appState.sessions.first { $0.id == appState.activeSessionID && !$0.isDeleted }
    }

    public var activeSessions: [Session] {
        appState.sessions.filter { !$0.isDeleted && !$0.isAutoDismissed }
    }

    public func setActiveSession(_ id: UUID) {
        appState.activeSessionID = id
        scheduleSave()
    }

    @discardableResult
    public func createSession(name: String) -> Session? {
        guard activeSessions.count < AppConstants.maxActiveSessions else {
            debugLog("PersistenceManager: Cannot create session — max \(AppConstants.maxActiveSessions) reached")
            return nil
        }

        let session = Session(name: name)
        appState.sessions.append(session)

        // If this is the only active session, make it active
        if activeSessions.count == 1 {
            appState.activeSessionID = session.id
        }

        scheduleSave()
        debugLog("PersistenceManager: Created session '\(name)'")
        return session
    }

    public func renameSession(_ id: UUID, to name: String) {
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
              !appState.sessions[index].isInbox else { return }
        appState.sessions[index].name = name
        scheduleSave()
    }

    public func deleteSession(_ id: UUID) {
        guard !pinnedSessionIDs.contains(id) else {
            // A durable write is staging a comment into this session. Validation
            // inside the write only compares the candidate against disk; it cannot
            // see a local deletion landing during the await, and the rebase would
            // re-apply it afterwards. The inactivity timer calls this unattended,
            // so the case is not hypothetical.
            deferredSessionDeletions.append(id)
            debugLog("PersistenceManager: Deferred deletion of pinned session \(id)")
            return
        }
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
              !appState.sessions[index].isInbox else { return }
        let now = Date()
        appState.sessions[index].isDeleted = true
        appState.sessions[index].deletedAt = now

        // Soft-delete all comments in this session
        for i in appState.comments.indices where appState.comments[i].sessionID == id && !appState.comments[i].isDeleted {
            appState.comments[i].isDeleted = true
            appState.comments[i].deletedAt = now
            appState.comments[i].updatedAt = now
        }

        // If this was the active session, switch to another
        if appState.activeSessionID == id {
            appState.activeSessionID = activeSessions.first?.id
        }

        removeClaudeCodeMarkerFile(for: appState.sessions[index])

        scheduleSave()
        debugLog("PersistenceManager: Deleted session")
    }

    /// Delete a stored image and every file derived from it.
    ///
    /// The one place image deletion happens, so no path can remove the primary
    /// PNG and leave its editing base behind. That matters more than it sounds:
    /// for an image annotated with vectors only, the base is a byte-for-byte
    /// copy of the original capture, so a missed sidecar means a permanently
    /// deleted comment's screenshot stays on disk.
    ///
    /// Callers are fire-and-forget deletion paths that cannot meaningfully
    /// recover, but the failure is logged rather than dropped: a surviving
    /// sidecar is what resurrects stale marks later.
    static func deleteImageFamily(_ relativePath: String) {
        do {
            try AnnotationMarkStore.deleteImageFamily(relativePath)
        } catch {
            debugLog("PersistenceManager: could not fully delete \(relativePath) - \(error)")
        }
    }

    public func permanentlyDeleteSession(_ id: UUID) {
        for comment in appState.comments where comment.sessionID == id {
            if let imagePath = comment.type.imagePath {
                Self.deleteImageFamily(imagePath)
            }
            for attachment in comment.attachments {
                Self.deleteImageFamily(attachment)
            }
        }
        appState.sessions.removeAll { $0.id == id }
        appState.comments.removeAll { $0.sessionID == id }
        scheduleSave()
    }

    public func restoreSession(_ id: UUID) {
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }) else { return }

        // Check if we can restore (max 3 active)
        guard activeSessions.count < AppConstants.maxActiveSessions else {
            debugLog("PersistenceManager: Cannot restore session — max active reached")
            return
        }

        appState.sessions[index].isDeleted = false
        appState.sessions[index].deletedAt = nil
        appState.sessions[index].isAutoDismissed = false
        appState.sessions[index].autoDismissedAt = nil

        // Restore comments that were deleted with the session
        let now = Date()
        for i in appState.comments.indices where appState.comments[i].sessionID == id && appState.comments[i].isDeleted {
            appState.comments[i].isDeleted = false
            appState.comments[i].deletedAt = nil
            appState.comments[i].updatedAt = now
        }

        if appState.activeSessionID == nil {
            appState.activeSessionID = id
        }

        scheduleSave()
    }

    public func dismissSession(_ id: UUID) {
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }) else { return }
        appState.sessions[index].isAutoDismissed = true
        appState.sessions[index].autoDismissedAt = Date()

        if appState.activeSessionID == id {
            appState.activeSessionID = activeSessions.first?.id
        }

        scheduleSave()
    }

    // MARK: - Attachment Image Saving

    /// Save an image as a PNG attachment, downsampling if larger than 2048px.
    /// Returns the relative path (e.g. "images/UUID.png") or nil on failure.
    public func saveAttachmentImage(_ image: NSImage) -> String? {
        let maxDimension: CGFloat = 2048
        var targetImage = image

        // Downsample if needed
        let size = image.size
        if max(size.width, size.height) > maxDimension {
            let scale = maxDimension / max(size.width, size.height)
            let newSize = NSSize(width: size.width * scale, height: size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            targetImage = resized
        }

        guard let pngData = targetImage.pngData() else {
            debugLog("PersistenceManager: Failed to create PNG data for attachment")
            return nil
        }

        let filename = "images/\(UUID().uuidString).png"
        let url = resolveImagePath(filename)
        do {
            try pngData.write(to: url)
            debugLog("PersistenceManager: Saved attachment image \(filename)")
            return filename
        } catch {
            debugLog("PersistenceManager: Failed to save attachment image — \(error)")
            return nil
        }
    }

    // MARK: - Comment Operations

    public func comments(for sessionID: UUID) -> [Comment] {
        appState.comments
            .filter { $0.sessionID == sessionID && !$0.isDeleted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public var allComments: [Comment] {
        appState.comments.filter { !$0.isDeleted }
    }

    public var activeComments: [Comment] {
        guard let activeID = appState.activeSessionID else { return [] }
        return comments(for: activeID)
    }

    @discardableResult
    public func createComment(type: CommentType, commentText: String, source: String, appBundleID: String?, attachments: [String] = [], webContext: WebContext? = nil, regionElements: [WebContext]? = nil, targetSessionID: UUID? = nil, wakeRequested: Bool = false) -> Comment? {
        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: commentText,
            attachments: attachments
        ) else {
            debugLog("PersistenceManager: Rejected empty Quick Note")
            return nil
        }
        let normalizedCommentText = Comment.normalizedCommentText(commentText)

        // Auto-create a session if none exists
        if appState.activeSessionID == nil || activeSession == nil {
            let session = Session(name: AppConstants.inboxSessionName)
            appState.sessions.append(session)
            appState.activeSessionID = session.id
            debugLog("PersistenceManager: Auto-created session '\(session.name)'")
        }

        // Use targetSessionID if provided, otherwise fall back to activeSessionID
        let sessionID = targetSessionID ?? appState.activeSessionID
        guard let sessionID else {
            debugLog("PersistenceManager: No active session for comment")
            return nil
        }

        // A wake comment is handed off the moment it is saved: the agent claims
        // it from there with a compare-and-set.
        let comment = Comment(
            type: type,
            commentText: normalizedCommentText,
            source: source,
            appBundleID: appBundleID,
            sessionID: sessionID,
            status: wakeRequested ? .handedOff : .open,
            attachments: attachments,
            webContext: webContext,
            regionElements: regionElements,
            wakeRequestedAt: wakeRequested ? Date() : nil
        )

        appState.comments.append(comment)
        appState.totalCommentsCreated += 1

        if wakeRequested {
            // The hooks watch this file; the comment has to be on disk before the
            // change event fires, or the woken session finds nothing to act on.
            saveNow()
        } else {
            scheduleSave()
        }
        debugLog("PersistenceManager: Created comment \(comment.shortID) (total: \(appState.totalCommentsCreated))")
        WebhookService.shared.dispatch(.commentCreated, comment: comment)
        return comment
    }

    @discardableResult
    public func updateComment(_ id: UUID, text: String, attachments: [String]? = nil) -> Bool {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return false }
        guard CommentSavePolicy.allowsSave(
            type: appState.comments[index].type,
            commentText: text,
            attachments: attachments ?? appState.comments[index].attachments
        ) else {
            debugLog("PersistenceManager: Rejected empty Quick Note update")
            return false
        }
        appState.comments[index].commentText = Comment.normalizedCommentText(text)
        if let attachments = attachments {
            appState.comments[index].attachments = attachments
        }
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        WebhookService.shared.dispatch(.commentUpdated, comment: appState.comments[index])
        return true
    }

    public func deleteComment(_ id: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        appState.comments[index].isDeleted = true
        appState.comments[index].deletedAt = now
        appState.comments[index].updatedAt = now
        scheduleSave()
        WebhookService.shared.dispatch(.commentDeleted, comment: appState.comments[index])
    }

    public func permanentlyDeleteComment(_ id: UUID) {
        if let comment = appState.comments.first(where: { $0.id == id }) {
            // Only announce if it wasn't already soft-deleted (which fired its own event).
            if !comment.isDeleted {
                WebhookService.shared.dispatch(.commentDeleted, comment: comment)
            }
            if let imagePath = comment.type.imagePath {
                Self.deleteImageFamily(imagePath)
                debugLog("PersistenceManager: Deleted image file \(imagePath)")
            }
            for attachment in comment.attachments {
                Self.deleteImageFamily(attachment)
                debugLog("PersistenceManager: Deleted attachment file \(attachment)")
            }
        }
        appState.comments.removeAll { $0.id == id }
        scheduleSave()
    }

    public func restoreComment(_ id: UUID, to sessionID: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].isDeleted = false
        appState.comments[index].deletedAt = nil
        appState.comments[index].sessionID = sessionID
        appState.comments[index].updatedAt = Date()
        scheduleSave()
    }

    public func restoreComments(_ ids: [UUID]) {
        let now = Date()
        for id in ids {
            guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { continue }
            appState.comments[index].isDeleted = false
            appState.comments[index].deletedAt = nil
            appState.comments[index].updatedAt = now
        }
        scheduleSave()
    }

    @discardableResult
    public func clearAllComments(in sessionID: UUID) -> [UUID] {
        let now = Date()
        var clearedIDs: [UUID] = []
        for index in appState.comments.indices {
            if appState.comments[index].sessionID == sessionID && !appState.comments[index].isDeleted {
                appState.comments[index].isDeleted = true
                appState.comments[index].deletedAt = now
                appState.comments[index].updatedAt = now
                clearedIDs.append(appState.comments[index].id)
                WebhookService.shared.dispatch(.commentDeleted, comment: appState.comments[index])
            }
        }
        scheduleSave()
        return clearedIDs
    }

    /// Soft-delete only the exact comment versions in a successful export.
    ///
    /// The comparison and mutation happen after a fresh read while holding the
    /// cross-process document lock. Checking only `appState` is unsafe: MCP can
    /// edit a comment on disk before its asynchronous reload notification reaches
    /// the app, and an in-memory check would then delete that newer version.
    @discardableResult
    public func clearExportedComments(
        _ receipt: ExportReceipt
    ) -> Result<[UUID], PersistenceError> {
        let candidate = appState
        let baseline = lastPersisted

        // This intentionally stays synchronous on the main actor. If it yielded
        // after taking `candidate`, an edit could land while the lock-held helper
        // was clearing the older version on disk. Repairing memory afterwards
        // would still leave a crash window before the compensating save. Keeping
        // the compare-and-set atomic with respect to app mutations avoids ever
        // committing that transient deletion. Cross-process writers remain
        // serialized by DocumentLock and are re-read inside the helper.
        do {
            let commit = try PersistenceManager.performExportReceiptClear(
                fileURL: fileURL,
                receipt: receipt,
                candidate: candidate,
                baseline: baseline
            )

            appState = commit.state
            lastPersisted = commit.state
            for id in commit.clearedIDs {
                if let comment = appState.comments.first(where: { $0.id == id }) {
                    WebhookService.shared.dispatch(.commentDeleted, comment: comment)
                }
            }
            return .success(commit.clearedIDs)
        } catch let error as PersistenceError {
            debugLog("PersistenceManager: Export clear failed - \(error)")
            return .failure(error)
        } catch {
            let persistenceError = PersistenceError.writeFailed("\(error)")
            debugLog("PersistenceManager: Export clear failed - \(persistenceError)")
            return .failure(persistenceError)
        }
    }

    public func moveComment(_ id: UUID, to sessionID: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].sessionID = sessionID
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        WebhookService.shared.dispatch(.commentUpdated, comment: appState.comments[index])
    }

    public func resolveComment(_ id: UUID, summary: String, resolvedBy: String) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].status = .resolved
        appState.comments[index].resolutionSummary = summary
        appState.comments[index].resolvedBy = resolvedBy
        appState.comments[index].resolvedAt = Date()
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        debugLog("PersistenceManager: Resolved comment \(id)")
        WebhookService.shared.dispatch(.commentResolved, comment: appState.comments[index])

        autoDeleteResolvedCommentIfImmediate(id)
    }

    public func reopenComment(_ id: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].status = .open
        appState.comments[index].resolutionSummary = nil
        appState.comments[index].resolvedBy = nil
        appState.comments[index].resolvedAt = nil
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        debugLog("PersistenceManager: Reopened comment \(id)")
        WebhookService.shared.dispatch(.commentStatusChanged, comment: appState.comments[index])
    }

    public func setCommentStatus(_ id: UUID, to status: CommentStatus) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = appState.comments[index].status
        appState.comments[index].status = status
        appState.comments[index].updatedAt = Date()
        if status == .resolved {
            // Set resolvedAt if not already set (for timed auto-delete)
            if appState.comments[index].resolvedAt == nil {
                appState.comments[index].resolvedAt = Date()
            }
        } else {
            // Clear resolution metadata when moving away from resolved
            appState.comments[index].resolutionSummary = nil
            appState.comments[index].resolvedBy = nil
            appState.comments[index].resolvedAt = nil
        }
        scheduleSave()
        debugLog("PersistenceManager: Set comment \(id) status to \(status.rawValue)")

        if previousStatus != status {
            WebhookService.shared.dispatch(
                status == .resolved ? .commentResolved : .commentStatusChanged,
                comment: appState.comments[index]
            )
        }

        // Auto-delete immediately if setting is .immediately
        if status == .resolved {
            autoDeleteResolvedCommentIfImmediate(id)
        }
    }

    // MARK: - Transcription Operations

    public var transcriptions: [Transcription] {
        appState.transcriptions
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func addTranscription(text: String, appBundleID: String?, appName: String?) -> Transcription {
        let transcription = Transcription(
            text: text,
            appBundleID: appBundleID,
            appName: appName
        )
        appState.transcriptions.append(transcription)
        scheduleSave()
        debugLog("PersistenceManager: Added transcription \(transcription.id.uuidString.prefix(8))")
        return transcription
    }

    public func deleteTranscription(_ id: UUID) {
        guard let index = appState.transcriptions.firstIndex(where: { $0.id == id }) else { return }
        appState.transcriptions[index].isDeleted = true
        appState.transcriptions[index].deletedAt = Date()
        scheduleSave()
    }

    public func permanentlyDeleteTranscription(_ id: UUID) {
        appState.transcriptions.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - History

    public var deletedComments: [Comment] {
        appState.comments.filter { $0.isDeleted }
    }

    public var deletedSessions: [Session] {
        appState.sessions.filter { $0.isDeleted || $0.isAutoDismissed }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveSubject.send()
    }

    /// Write our state, merged with whatever landed on disk since we last read
    /// it, under the cross-process lock.
    ///
    /// The app is one of several writers (MCP tools and hooks mutate the same
    /// file). Writing our long-lived in-memory snapshot directly used to erase
    /// their commits - an agent resolving a comment, then any UI edit reverting
    /// it. Locking alone does not fix that: the snapshot itself is stale, so we
    /// re-read and merge inside the lock.
    /// Routine save: does the locked read-merge-write on a background actor so
    /// contention with another process never blocks the UI.
    private func saveToDisk() {
        // A durable write owns the document. Running now would merge against a
        // baseline it is about to replace, publishing state computed from an
        // older snapshot over the newer one. `saveToDiskBlocking` deliberately
        // does NOT take this gate: its whole purpose is that the bytes are on
        // disk before it returns, and it re-reads and merges under the lock, so
        // a concurrent durable commit is picked up rather than lost.
        guard !documentWriteInFlight else {
            deferredSaveRequested = true
            return
        }
        // Coalesce rather than drop: a request arriving mid-save means the
        // in-flight snapshot is already stale, so remember to run again. The
        // previous guard discarded that request entirely and then assigned the
        // stale merged result back over newer edits, deleting them.
        guard !backgroundSaveInFlight else {
            backgroundSaveRequested = true
            return
        }
        backgroundSaveInFlight = true
        let ours = appState
        let base = lastPersisted
        let url = fileURL
        Task { [weak self] in
            let merged = await self?.documentWriter.save(fileURL: url, base: base, ours: ours)
            await MainActor.run {
                guard let self else { return }
                self.backgroundSaveInFlight = false
                guard let merged else {
                    // Lock busy or write failed: state stays in memory, and a
                    // later mutation retries.
                    debugLog("PersistenceManager: Save deferred - could not acquire document lock")
                    if self.backgroundSaveRequested {
                        self.backgroundSaveRequested = false
                        self.saveToDisk()
                    }
                    return
                }
                self.lastPersisted = merged
                if self.appState == ours {
                    // Nothing changed while we were writing: adopting the
                    // merged document is safe and picks up other processes'
                    // commits.
                    if merged != self.appState { self.appState = merged }
                } else {
                    // Edits landed mid-save. Keep them and write again rather
                    // than overwriting with the older snapshot.
                    self.backgroundSaveRequested = true
                }
                if self.backgroundSaveRequested {
                    self.backgroundSaveRequested = false
                    self.saveToDisk()
                }
            }
        }
    }

    /// Blocking variant for the two places that genuinely need the bytes on
    /// disk before returning: the wake button (the hooks watch this file, so a
    /// comment must be readable before the change event fires) and termination.
    @discardableResult
    private func saveToDiskBlocking() -> Bool {
        do {
            try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent:
                    onDisk = lastPersisted
                case .decoded(let decoded):
                    onDisk = decoded
                case .unreadable(let reason):
                    throw DocumentUnreadable(reason: reason)
                }
                let merged = AppStateMerge.merge(base: lastPersisted, ours: appState, theirs: onDisk)
                let data = try JSONEncoder().encode(merged)
                try data.write(to: fileURL, options: .atomic)
                lastPersisted = merged
                if merged != appState { appState = merged }
            }
            return true
        } catch is DocumentLock.TimedOut {
            debugLog("PersistenceManager: Blocking save skipped - could not acquire document lock")
            return false
        } catch let error as DocumentUnreadable {
            DocumentRecovery.dump(appState, beside: fileURL, reason: error.reason)
            return false
        } catch {
            debugLog("PersistenceManager: Failed to save - \(error)")
            return false
        }
    }

    // MARK: - Durable creation

    /// Create a comment and return only once it is provably on disk.
    ///
    /// `createComment` cannot do this on either of its branches. The debounced
    /// branch has not written anything yet when it returns, the `wakeRequested`
    /// branch reaches `saveToDisk`, which swallows every error including a lock
    /// timeout, and its only `nil` return is guarded by a session it created
    /// moments earlier. A non-nil return therefore proves nothing, which is fine
    /// for a menu action and not fine for a capture that tears down an overlay, a
    /// draft, and an annotation session on the strength of it.
    ///
    /// This goes through the same cross-process protocol as every other write:
    /// acquire the lock, re-read, three-way merge against `lastPersisted`, encode,
    /// atomic rename. Writing the staged candidate directly would erase whatever
    /// the MCP server and hooks committed in between.
    ///
    /// Not cancellable once the helper has entered the lock. A cancelled task
    /// still completes the write and the publish, because abandoning between the
    /// rename and the publish would leave the document written but unknown to
    /// memory. Callers cancel before preparing, not during.
    public func createCommentDurably(
        type: CommentType,
        commentText: String,
        source: String,
        appBundleID: String?,
        attachments: [String] = [],
        webContext: WebContext? = nil,
        regionElements: [WebContext]? = nil,
        targetSessionID: UUID? = nil,
        wakeRequested: Bool = false
    ) async -> Result<Comment, PersistenceError> {

        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: commentText,
            attachments: attachments
        ) else {
            debugLog("PersistenceManager: Rejected empty Quick Note from durable create")
            return .failure(.invalidComment)
        }

        await acquireDocumentSlot()

        // Snapshotted BEFORE the candidate is built. This is the merge base on
        // the way back, and naming it wrongly deletes the comment that was just
        // written: with `candidate` as the base, the new comment is present in
        // both base and theirs but absent from the current `appState`, and
        // `mergeEntities` appends a theirs-only entity only when it is absent
        // from base. It would be dropped from memory, then from disk.
        let launchState = appState

        var candidate = appState
        let sessionID: UUID
        if let targetSessionID {
            sessionID = targetSessionID
        } else if let active = candidate.activeSessionID,
                  candidate.sessions.contains(where: { $0.id == active && !$0.isDeleted }) {
            sessionID = active
        } else {
            let session = Session(name: AppConstants.inboxSessionName)
            candidate.sessions.append(session)
            candidate.activeSessionID = session.id
            sessionID = session.id
            debugLog("PersistenceManager: Auto-created session '\(session.name)' for durable create")
        }

        let comment = Comment(
            type: type,
            commentText: Comment.normalizedCommentText(commentText),
            source: source,
            appBundleID: appBundleID,
            sessionID: sessionID,
            status: wakeRequested ? .handedOff : .open,
            attachments: attachments,
            webContext: webContext,
            regionElements: regionElements,
            wakeRequestedAt: wakeRequested ? Date() : nil
        )
        candidate.comments.append(comment)
        // Inside the candidate, never applied afterwards: the counter is part of
        // the encoded document and the merge resolves it by max, so incrementing
        // after the write would diverge memory from disk.
        candidate.totalCommentsCreated += 1

        pinnedSessionIDs.insert(sessionID)

        let url = fileURL
        let baseline = lastPersisted
        let staged = candidate

        let outcome: Result<AppState, PersistenceError>
        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                try PersistenceManager.performDocumentWrite(
                    fileURL: url, candidate: staged, baseline: baseline, requiredSessionID: sessionID)
            }.value
            outcome = .success(merged)
        } catch let error as PersistenceError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.writeFailed("\(error)"))
        }

        pinnedSessionIDs.remove(sessionID)

        switch outcome {
        case .failure(let error):
            debugLog("PersistenceManager: Durable create failed - \(error)")
            releaseDocumentSlot()
            return .failure(error)

        case .success(let merged):
            appState = AppStateMerge.merge(base: launchState, ours: appState, theirs: merged)
            lastPersisted = merged

            guard let stored = appState.comments.first(where: { $0.id == comment.id }) else {
                // Unreachable: an entity present in ours and absent from base takes
                // the "we created it" branch of mergeEntities and is appended
                // unchanged. Treated as a failure rather than asserted, because
                // returning a comment the caller cannot find is worse.
                debugLog("PersistenceManager: Durable create lost the comment in rebase")
                releaseDocumentSlot()
                return .failure(.writeFailed("comment absent after rebase"))
            }

            if appState != merged {
                // Local edits made during the await are still only in memory.
                scheduleSave()
            }
            debugLog("PersistenceManager: Durably created comment \(stored.shortID) (total: \(appState.totalCommentsCreated))")
            releaseDocumentSlot()
            // Dispatched after publication, and exactly once from this process.
            // Not end-to-end exactly-once: dispatch is fire-and-forget with up to
            // three attempts, so an ambiguous response can still arrive twice at
            // the receiver, and a crash between the rename and this line loses the
            // event. A real guarantee needs an outbox plus receiver idempotency.
            WebhookService.shared.dispatch(.commentCreated, comment: stored)
            return .success(stored)
        }
    }

    /// One lock-held read, merge, encode, and atomic rename, off the main actor.
    ///
    /// `DocumentLock.acquire` polls with `Thread.sleep` up to a 2s timeout, and
    /// this sits on the capture save's critical path during the fly animation.
    /// `AppState` is a value type, so the candidate crosses by copy.
    ///
    /// Internal rather than private so tests can drive it against a temporary
    /// file. Exercising it through the singleton would mutate the real
    /// `comments.json` in the user's Application Support directory.
    nonisolated static func performDocumentWrite(
        fileURL: URL,
        candidate: AppState,
        baseline: AppState,
        requiredSessionID: UUID?
    ) throws -> AppState {
        do {
            return try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    // Propagate read and decode errors instead of falling back to
                    // the baseline the way `saveToDisk` does. Overwriting a
                    // malformed, briefly unreadable, or forward-incompatible
                    // document with stale state destroys whatever a newer build
                    // wrote. The only permitted fallback is a missing file.
                    let data: Data
                    do { data = try Data(contentsOf: fileURL) }
                    catch { throw PersistenceError.documentUnreadable("\(error)") }
                    do { onDisk = try JSONDecoder().decode(AppState.self, from: data) }
                    catch { throw PersistenceError.documentUnreadable("\(error)") }
                } else {
                    onDisk = AppState.defaultState()
                }

                let merged = AppStateMerge.merge(base: baseline, ours: candidate, theirs: onDisk)

                // Sessions merge as whole entities, so another writer soft-deleting
                // the target wins for that untouched session while the new comment
                // still points at it. Deleted sessions are excluded from
                // navigation, so the comment would exist and be invisible. Fail
                // instead; v1 does not silently reparent to Inbox.
                if let requiredSessionID {
                    guard let session = merged.sessions.first(where: { $0.id == requiredSessionID }),
                          !session.isDeleted,
                          // `activeSessions` filters on BOTH flags, so an
                          // auto-dismissed target leaves the comment just as
                          // unreachable as a deleted one.
                          !session.isAutoDismissed else {
                        throw PersistenceError.sessionUnavailable
                    }
                }

                let encoded: Data
                do { encoded = try JSONEncoder().encode(merged) }
                catch { throw PersistenceError.encodeFailed("\(error)") }
                do { try encoded.write(to: fileURL, options: .atomic) }
                catch { throw PersistenceError.writeFailed("\(error)") }
                return merged
            }
        } catch is DocumentLock.TimedOut {
            throw PersistenceError.lockTimeout
        }
    }

    struct ExportClearCommit: Sendable {
        let state: AppState
        let clearedIDs: [UUID]
    }

    /// Lock-held compare-and-set for post-export clearing.
    ///
    /// `candidate` carries app edits that have not reached disk yet. It is merged
    /// with the fresh on-disk document first; only versions that still match the
    /// export receipt after that merge are soft-deleted. Internal for tests so
    /// adversarial disk races can be exercised without touching user data.
    nonisolated static func performExportReceiptClear(
        fileURL: URL,
        receipt: ExportReceipt,
        candidate: AppState,
        baseline: AppState
    ) throws -> ExportClearCommit {
        do {
            return try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent:
                    onDisk = AppState.defaultState()
                case .decoded(let decoded):
                    onDisk = decoded
                case .unreadable(let reason):
                    throw PersistenceError.documentUnreadable(reason)
                }

                var merged = AppStateMerge.merge(
                    base: baseline,
                    ours: candidate,
                    theirs: onDisk
                )
                let clearableIDs = receipt.clearableCommentIDs(in: merged.comments)
                let clearableSet = Set(clearableIDs)
                let now = Date()

                for index in merged.comments.indices
                    where clearableSet.contains(merged.comments[index].id) {
                    merged.comments[index].isDeleted = true
                    merged.comments[index].deletedAt = now
                    merged.comments[index].updatedAt = now
                }

                let encoded: Data
                do { encoded = try JSONEncoder().encode(merged) }
                catch { throw PersistenceError.encodeFailed("\(error)") }
                do { try encoded.write(to: fileURL, options: .atomic) }
                catch { throw PersistenceError.writeFailed("\(error)") }

                return ExportClearCommit(state: merged, clearedIDs: clearableIDs)
            }
        } catch is DocumentLock.TimedOut {
            throw PersistenceError.lockTimeout
        }
    }

    // MARK: - Prepared-capture leases

    /// True when any comment (including soft-deleted ones), attachment, or
    /// retained orphan still points at `relativePath`.
    ///
    /// Soft-deleted comments count: their images are retained on purpose until
    /// the separate image-retention cutoff.
    public func referencesImage(_ relativePath: String) -> Bool {
        for comment in appState.comments {
            if case .screenshot(let imagePath) = comment.type, imagePath == relativePath { return true }
            if comment.attachments.contains(relativePath) { return true }
        }
        return appState.orphanedImages.contains { $0.path == relativePath }
    }

    /// Delete prepared PNGs left behind by a process that is confirmed gone.
    /// Never enumerates the images directory.
    private func reconcilePreparedCaptureLeases() {
        let result = PreparedCaptureLeaseRegistry.reconcile { [weak self] path in
            guard let self else { return true }   // cannot prove unreferenced: keep
            return self.referencesImage(path)
        }
        guard !result.deleted.isEmpty || !result.keptReferenced.isEmpty
                || !result.rejectedPath.isEmpty else { return }
        debugLog("PersistenceManager: Lease reconcile - deleted \(result.deleted.count), "
                 + "kept referenced \(result.keptReferenced.count), "
                 + "kept live \(result.keptLive.count), rejected path \(result.rejectedPath.count)")
    }

    // MARK: - Document slot

    private func acquireDocumentSlot() async {
        while documentWriteInFlight {
            await withCheckedContinuation { continuation in
                documentSlotWaiters.append(continuation)
            }
        }
        documentWriteInFlight = true
    }

    private func releaseDocumentSlot() {
        documentWriteInFlight = false

        if !documentSlotWaiters.isEmpty {
            // Hand off to the next durable write. Deferred saves and reloads run
            // when the chain finally drains, not between links.
            let next = documentSlotWaiters.removeFirst()
            next.resume()
            return
        }

        let wantsReload = deferredReloadRequested
        let wantsSave = deferredSaveRequested
        deferredReloadRequested = false
        deferredSaveRequested = false

        if wantsReload {
            // Suppression of a duplicate creation webhook is structural: the
            // comment is already published to `appState`, so the reload diff sees
            // it on both sides and emits nothing for it. reloadFromDisk flushes
            // pending edits itself, so a deferred save needs no separate run.
            reloadFromDisk()
        } else if wantsSave {
            saveToDisk()
        }

        applyDeferredSessionDeletions()
    }

    private func applyDeferredSessionDeletions() {
        guard !deferredSessionDeletions.isEmpty else { return }
        let pending = deferredSessionDeletions
        deferredSessionDeletions.removeAll()
        for id in pending {
            // Skip it if the transaction we deferred behind put a live comment in
            // there. `deleteSession` soft-deletes every comment in the session, so
            // applying it here would destroy the comment the durable write just
            // reported as saved - and the unattended inactivity timer is one of the
            // callers, so nobody would have asked for that.
            let hasFreshComment = appState.comments.contains {
                $0.sessionID == id && !$0.isDeleted
            }
            guard !hasFreshComment else {
                debugLog("PersistenceManager: Dropped deferred deletion of session \(id) - it now holds a live comment")
                continue
            }
            deleteSession(id)
        }
    }

    /// Save synchronously, bypassing the debounce.
    ///
    /// Used by the wake CTA: the hooks watch this file, so the comment has to
    /// be on disk before the event fires, or the woken session finds nothing.
    public func saveNow() {
        saveToDiskBlocking()
    }

    /// Synchronous save for app termination.
    ///
    /// Forced past the in-flight guard: see `saveToDisk(force:)`. Without this a
    /// quit landing inside a durable write's await window silently discards
    /// everything typed since the last debounce.
    public func saveImmediately() {
        saveToDiskBlocking()
    }

    private func reloadFromDisk() {
        guard !documentWriteInFlight else {
            // Adopting disk state mid-transaction would overwrite `appState` and
            // `lastPersisted` with a snapshot the durable write is about to
            // supersede. Run once it publishes instead.
            deferredReloadRequested = true
            return
        }
        // Flush anything pending before adopting disk state. Cancelling instead
        // (the old behaviour) silently dropped in-flight UI edits whenever an
        // agent wrote to the file. If the flush fails we must NOT continue:
        // replacing appState from disk would discard exactly the edits the
        // flush could not write.
        guard saveToDiskBlocking() else {
            debugLog("PersistenceManager: Reload aborted - could not flush pending edits")
            return
        }
        saveCancellable?.cancel()
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.saveToDisk()
            }

        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            debugLog("PersistenceManager: Failed to reload from disk")
            return
        }
        let previousComments = appState.comments
        let previousSessions = appState.sessions
        appState = state
        // Adopt the reloaded document as the merge baseline too. Leaving it
        // stale would make the next save treat every externally-made change as
        // a local edit, so "ours wins" could re-assert values we never touched.
        lastPersisted = state
        debugLog("PersistenceManager: Reloaded from disk (\(state.comments.count) comments, \(state.sessions.count) sessions)")

        // Out-of-process writers (MCP server, CLI) mutate comments.json directly,
        // so their changes never pass through the mutators above. Diff old vs new
        // state to fire webhooks for agent-driven changes too.
        if SettingsManager.shared.webhooks.contains(where: { $0.isEnabled }) {
            let events = WebhookEventDiff.events(
                old: previousComments,
                new: state.comments,
                oldSessions: previousSessions,
                newSessions: state.sessions
            )
            for (event, comment) in events {
                WebhookService.shared.dispatch(event, comment: comment)
            }
        }

        autoDeleteResolvedComments()
        autoDeleteInactiveSessions()
    }

    // MARK: - Resolved Comment Auto-Deletion

    /// Soft-delete a single resolved comment if the setting is `.immediately`.
    /// Delays briefly so the resolved state change is visible before the comment disappears.
    private func autoDeleteResolvedCommentIfImmediate(_ id: UUID) {
        guard SettingsManager.shared.resolvedCommentDeletion == .immediately else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let index = appState.comments.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
            let sessionID = appState.comments[index].sessionID
            let now = Date()
            appState.comments[index].isDeleted = true
            appState.comments[index].deletedAt = now
            appState.comments[index].updatedAt = now
            scheduleSave()
            debugLog("PersistenceManager: Immediately auto-deleted resolved comment \(id)")
            ToastManager.shared.show("Auto-deleted", undo: { [weak self] in
                self?.restoreComment(id, to: sessionID)
            })
        }
    }

    /// Scan all resolved comments and soft-delete those whose interval has expired.
    private func autoDeleteResolvedComments() {
        let setting = SettingsManager.shared.resolvedCommentDeletion
        guard let interval = setting.interval else { return } // .never → no-op

        let now = Date()
        var didDelete = false
        for index in appState.comments.indices {
            let comment = appState.comments[index]
            guard comment.status == .resolved && !comment.isDeleted else { continue }
            let resolvedAt = comment.resolvedAt ?? comment.updatedAt
            if now.timeIntervalSince(resolvedAt) >= interval {
                appState.comments[index].isDeleted = true
                appState.comments[index].deletedAt = now
                appState.comments[index].updatedAt = now
                didDelete = true
            }
        }
        if didDelete {
            scheduleSave()
            debugLog("PersistenceManager: Auto-deleted expired resolved comments (setting: \(setting.rawValue))")
        }
    }

    /// Start or stop the 60-second repeating timer based on the deletion setting.
    private func updateResolvedDeletionTimer(for setting: SettingsManager.ResolvedCommentDeletion) {
        resolvedDeletionTimer?.invalidate()
        resolvedDeletionTimer = nil

        // Only need a timer for timed delays (not .never or .immediately)
        guard setting.interval != nil && setting != .immediately else { return }

        resolvedDeletionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoDeleteResolvedComments()
            }
        }
        debugLog("PersistenceManager: Started resolved deletion timer (setting: \(setting.rawValue))")
    }

    // MARK: - Inactive Session Auto-Deletion

    private func lastActivity(for session: Session) -> Date {
        let latestComment = appState.comments
            .filter { $0.sessionID == session.id && !$0.isDeleted }
            .map { $0.updatedAt }
            .max()
        return max(session.createdAt, latestComment ?? .distantPast)
    }

    /// Exempts only Inbox. Inactivity alone determines deletion — the active session and
    /// sessions with open comments are NOT exempt, since `activeSessionID` is sticky and
    /// unresolved comments on an untouched session are stale, not in-flight.
    private func autoDeleteInactiveSessions() {
        let settings = SettingsManager.shared
        guard settings.inactiveSessionCleanupEnabled else { return }
        let interval = settings.inactiveSessionCleanupInterval.interval

        let now = Date()
        let candidateIDs: [UUID] = activeSessions.compactMap { session in
            guard !session.isInbox else { return nil }
            guard now.timeIntervalSince(lastActivity(for: session)) >= interval else { return nil }
            return session.id
        }

        for id in candidateIDs {
            deleteSession(id)
        }
        if !candidateIDs.isEmpty {
            debugLog("PersistenceManager: Auto-deleted \(candidateIDs.count) inactive session(s)")
        }
    }

    private func updateInactiveSessionTimer() {
        inactiveSessionTimer?.invalidate()
        inactiveSessionTimer = nil

        guard SettingsManager.shared.inactiveSessionCleanupEnabled else { return }

        inactiveSessionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoDeleteInactiveSessions() }
        }
        debugLog("PersistenceManager: Started inactive session timer")

        // Run immediately so toggling on takes effect without waiting 60s
        autoDeleteInactiveSessions()
    }

    // MARK: - Claude Code Marker Cleanup

    /// Marker files at /tmp/remarc-claude-<claudeSessionId>.marker are used by the SessionEnd
    /// hook to locate which Remarc session to wind down. Abnormal Claude Code exits (kill,
    /// terminal close) skip the hook and leave the marker pinned, which pins the Remarc
    /// session. Couple marker cleanup to session deletion so they can't outlive it.
    private func removeClaudeCodeMarkerFile(for session: Session) {
        guard let claudeSessionId = session.claudeCodeSessionId else { return }
        let path = AppConstants.claudeCodeMarkerPath(for: claudeSessionId)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Launch-time sweep for markers whose Remarc session is missing or already deleted —
    /// catches cruft from versions before marker cleanup was coupled to deleteSession.
    private func cleanupStaleClaudeCodeMarkers() {
        let tmpDir = AppConstants.claudeCodeMarkerDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else { return }
        let prefix = AppConstants.claudeCodeMarkerPrefix
        let suffix = AppConstants.claudeCodeMarkerSuffix
        var removed = 0
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let claudeSessionId = String(entry.dropFirst(prefix.count).dropLast(suffix.count))
            let session = appState.sessions.first { $0.claudeCodeSessionId == claudeSessionId }
            guard session?.isDeleted ?? true else { continue }
            try? FileManager.default.removeItem(atPath: "\(tmpDir)/\(entry)")
            removed += 1
        }
        if removed > 0 {
            debugLog("PersistenceManager: Cleaned up \(removed) stale Claude Code marker file(s)")
        }
    }

    private func pruneExpiredHistory() {
        let historyRetention = SettingsManager.shared.historyRetentionDays
        let imageRetention = SettingsManager.shared.imageRetentionDays
        let transcriptionRetention = SettingsManager.shared.transcriptionRetentionDays
        let now = Date()
        let historyCutoff = Calendar.current.date(byAdding: .day, value: -historyRetention, to: now) ?? now
        let imageCutoff = Calendar.current.date(byAdding: .day, value: -imageRetention, to: now) ?? now
        let transcriptionCutoff = Calendar.current.date(byAdding: .day, value: -transcriptionRetention, to: now) ?? now

        let commentsBefore = appState.comments.count
        let sessionsBefore = appState.sessions.count

        // Pass 1: Prune comment records, orphan their images
        for comment in appState.comments where comment.isDeleted && (comment.deletedAt ?? Date.distantFuture) < historyCutoff {
            let deletedAt = comment.deletedAt ?? now
            if let imagePath = comment.type.imagePath {
                appState.orphanedImages.append(OrphanedImage(path: imagePath, deletedAt: deletedAt))
            }
            for attachment in comment.attachments {
                appState.orphanedImages.append(OrphanedImage(path: attachment, deletedAt: deletedAt))
            }
        }

        appState.comments.removeAll { comment in
            comment.isDeleted && (comment.deletedAt ?? Date.distantFuture) < historyCutoff
        }

        appState.sessions.removeAll { session in
            session.isDeleted && (session.deletedAt ?? Date.distantFuture) < historyCutoff
        }

        // Pass 2: Prune orphaned images past image retention
        let orphansBefore = appState.orphanedImages.count
        for orphan in appState.orphanedImages where orphan.deletedAt < imageCutoff {
            Self.deleteImageFamily(orphan.path)
            debugLog("PersistenceManager: Pruned orphaned image \(orphan.path)")
        }

        // Sweep up pairs stranded by an older build or by a delete that failed
        // partway. Without this, sidecars orphaned before deleteImageFamily
        // existed would never be collected by anything.
        AnnotationMarkStore.removeOrphanedSidecars()

        appState.orphanedImages.removeAll { $0.deletedAt < imageCutoff }

        // Pass 3: Prune old transcriptions (soft-deleted or past retention)
        let transcriptionsBefore = appState.transcriptions.count
        appState.transcriptions.removeAll { transcription in
            if transcription.isDeleted, let deletedAt = transcription.deletedAt {
                return deletedAt < historyCutoff
            }
            return transcription.createdAt < transcriptionCutoff
        }
        let transcriptionsRemoved = transcriptionsBefore - appState.transcriptions.count

        let commentsRemoved = commentsBefore - appState.comments.count
        let sessionsRemoved = sessionsBefore - appState.sessions.count
        let orphansRemoved = orphansBefore - appState.orphanedImages.count

        if commentsRemoved > 0 || sessionsRemoved > 0 || orphansRemoved > 0 || transcriptionsRemoved > 0 {
            debugLog("PersistenceManager: Pruned \(commentsRemoved) comments, \(sessionsRemoved) sessions, \(orphansRemoved) orphaned images, \(transcriptionsRemoved) transcriptions")
            scheduleSave()
        }
    }
}
