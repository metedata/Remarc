import Foundation
import CoreGraphics
import CryptoKit

/// Durable storage for re-editable annotations.
///
/// Three files per annotated image, all inside `Remarc/images`:
///
/// - `<uuid>.png`        the flattened result. Unchanged in role: thumbnails,
///                       Copy, Save As and every export still read only this.
/// - `<uuid>.base.png`   the editing base. The capture with every REDACTION
///                       already flattened into its pixels.
/// - `<uuid>.marks.json` the vector marks that sit on top of that base.
///
/// The base is not the untouched original, and that is the point. Storing a
/// pristine capture beside its obscured copy would leave whatever the user
/// blurred one filename away. Redactions flatten on the first Apply; only
/// vectors stay editable.
///
/// **These are visual obscuration, not secure redaction.** `CIPixellate`
/// point-samples each cell rather than averaging it, so an obscured region
/// still contains real original pixel values subsampled to one per cell, in
/// both the flattened PNG and the base. Do not describe them as removing the
/// underlying content. See `AnnotationFilters`.
public enum AnnotationMarkStore {

    /// Bumped when the stored shape changes in a way older builds cannot read.
    public static let currentVersion = 1

    /// Read before the payload, so a version bump is an actual migration
    /// boundary. Decoding the whole current-schema document first and checking
    /// `version` afterwards cannot work: a v2 document that changed an item
    /// representation - the only reason to bump - fails to decode before its
    /// version is ever inspected.
    private struct Envelope: Codable {
        var version: Int
    }

    public struct Document: Codable {
        public var version: Int
        /// SHA-256 of the flattened PNG these marks were written against.
        ///
        /// This is what makes a stale pair detectable. Apply commits the PNG
        /// before it writes the sidecar, so a crash in between used to leave an
        /// older base+marks pair that still parsed, still looked complete, and
        /// would resurrect deleted marks or re-expose pixels the newer redaction
        /// covered. Binding to the bytes means the mismatch is caught on read
        /// instead of depending on write ordering surviving a crash.
        public var imageFingerprint: String
        public var items: [AnnotationItem]

        public init(version: Int = AnnotationMarkStore.currentVersion,
                    imageFingerprint: String,
                    items: [AnnotationItem]) {
            self.version = version
            self.imageFingerprint = imageFingerprint
            self.items = items
        }
    }

    /// What a saved image can be re-opened with.
    public struct Restored {
        /// Redactions already flattened in.
        public let base: CGImage
        public let items: [AnnotationItem]
    }

    // MARK: - Paths

    /// `images/x.png` -> `images/x.base.png`. Derived from the image path so the
    /// three files always travel together.
    static func basePath(for relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension + ".base.png"
    }

    static func marksPath(for relativePath: String) -> String {
        (relativePath as NSString).deletingPathExtension + ".marks.json"
    }

    static let baseSuffix = ".base.png"
    static let marksSuffix = ".marks.json"

    // MARK: - Reading

    /// The editable state for a stored image, or nil when it has none.
    ///
    /// Nil is the ordinary answer, not an error: every image captured before
    /// this feature, and every image never annotated, has no sidecar. The
    /// caller falls back to annotating the flattened PNG, which is exactly the
    /// behaviour that shipped before.
    public static func restore(for relativePath: String) -> Restored? {
        // Reads go through the same containment guard as writes. A corrupt or
        // externally supplied path with `..` in it would otherwise decode a file
        // outside Remarc/images.
        guard let marksURL = try? ownedURL(for: marksPath(for: relativePath)),
              let data = try? Data(contentsOf: marksURL) else { return nil }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // A sidecar we cannot parse must not take the image down with it.
            // The flattened PNG still holds every mark as pixels.
            debugLog("AnnotationMarkStore: unreadable marks for \(relativePath); annotating flat")
            return nil
        }
        guard envelope.version <= currentVersion else {
            debugLog("AnnotationMarkStore: marks v\(envelope.version) newer than v\(currentVersion)")
            return nil
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            debugLog("AnnotationMarkStore: v\(envelope.version) marks failed to decode")
            return nil
        }

        // The marks must belong to the image on screen. A mismatch means the
        // PNG moved on without them - an interrupted Apply, or an external
        // rewrite - and replaying them would redraw marks that are already
        // pixels or lift a redaction that has since been applied.
        guard let fingerprint = fingerprint(of: relativePath),
              fingerprint == document.imageFingerprint else {
            debugLog("AnnotationMarkStore: marks do not match the stored image for \(relativePath)")
            return nil
        }

        guard let base = AnnotationExporter.decode(relativePath: basePath(for: relativePath)) else {
            debugLog("AnnotationMarkStore: marks present but base missing for \(relativePath)")
            return nil
        }
        return Restored(base: base, items: document.items)
    }

    /// Whether reopening this image would restore editable marks. Answers by
    /// doing the real thing: a present-but-stale pair is not editable state.
    public static func hasEditableMarks(for relativePath: String) -> Bool {
        restore(for: relativePath) != nil
    }

    /// SHA-256 of a stored file's bytes, or nil when it cannot be read.
    private static func fingerprint(of relativePath: String) -> String? {
        guard let url = try? ownedURL(for: relativePath),
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writing

    /// Persist the editing base and the vector marks that sit on it.
    ///
    /// `flattenedPNG` is the bytes already committed as `<uuid>.png`; the marks
    /// are fingerprinted against it so a later read can tell whether the two
    /// still belong together.
    ///
    /// Clears any previous pair first, then writes base, then marks. Each file
    /// is atomic on its own, but the pair has to agree with each other, so every
    /// interrupted write leaves an incomplete set, which `restore` reads as
    /// "nothing editable" and falls back from safely. The cost of that fallback
    /// is editability, never content: the flattened PNG is written before any of
    /// this and still holds every mark.
    public static func write(base: CGImage,
                             items: [AnnotationItem],
                             flattenedPNG: Data,
                             for relativePath: String) throws {
        try removeSidecars(for: relativePath)

        try writeOwnedFile(AnnotationExporter.pngData(from: base),
                           to: basePath(for: relativePath))

        let fingerprint = SHA256.hash(data: flattenedPNG)
            .map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeOwnedFile(try encoder.encode(Document(imageFingerprint: fingerprint, items: items)),
                           to: marksPath(for: relativePath))
    }

    // MARK: - Deleting

    /// Drop the editable state, leaving the flattened PNG untouched.
    ///
    /// Throws rather than swallowing: a sidecar that survives a delete is the
    /// exact thing that resurrects stale marks, so a caller that cannot remove
    /// one needs to know.
    public static func removeSidecars(for relativePath: String) throws {
        for path in [basePath(for: relativePath), marksPath(for: relativePath)] {
            try removeOwnedFileIfPresent(path)
        }
    }

    /// Delete a stored image and everything derived from it.
    ///
    /// The single entry point for getting rid of an image. Deleting only the
    /// primary PNG leaves `<uuid>.base.png` behind, and for an image annotated
    /// with vectors only, that base is a byte-for-byte copy of the original
    /// capture - so a comment the user permanently deleted would leave its
    /// screenshot on disk indefinitely.
    public static func deleteImageFamily(_ relativePath: String) throws {
        try removeOwnedFileIfPresent(relativePath)
        try removeSidecars(for: relativePath)
    }

    /// Remove sidecars whose primary image is gone.
    ///
    /// Reconciliation for pairs stranded by an older build, by a delete path
    /// that predates `deleteImageFamily`, or by a partial failure. Returns the
    /// number of files removed.
    @discardableResult
    public static func removeOrphanedSidecars() -> Int {
        let imagesDir = remarcAppSupportURL.appendingPathComponent("images", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) else {
            return 0
        }

        var removed = 0
        for name in names {
            let suffix: String
            if name.hasSuffix(baseSuffix) { suffix = baseSuffix }
            else if name.hasSuffix(marksSuffix) { suffix = marksSuffix }
            else { continue }

            let primary = "images/" + String(name.dropLast(suffix.count)) + ".png"
            guard !FileManager.default.fileExists(atPath: resolveImagePath(primary).path) else {
                continue
            }
            do {
                try removeOwnedFileIfPresent("images/" + name)
                removed += 1
            } catch {
                debugLog("AnnotationMarkStore: could not remove orphaned \(name) - \(error)")
            }
        }
        if removed > 0 {
            debugLog("AnnotationMarkStore: removed \(removed) orphaned sidecar file(s)")
        }
        return removed
    }

    // MARK: - Containment

    /// Same guard as `AnnotationExporter.replaceOwnedImage`: both sides resolved
    /// through `standardizedFileURL` and `resolvingSymlinksInPath` before
    /// comparison, so `..` traversal and a symlinked images directory land on
    /// the real path rather than a string that merely looks contained.
    private static func ownedURL(for relativePath: String) throws -> URL {
        let imagesDir = remarcAppSupportURL
            .appendingPathComponent("images", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let target = resolveImagePath(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()

        guard target.pathComponents.count == imagesDir.pathComponents.count + 1,
              target.deletingLastPathComponent().path == imagesDir.path else {
            throw AnnotationExporter.ExportError.notOwnedPath(relativePath)
        }
        return target
    }

    private static func writeOwnedFile(_ data: Data, to relativePath: String) throws {
        let url = try ownedURL(for: relativePath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AnnotationExporter.ExportError.writeFailed("\(error)")
        }
    }

    private static func removeOwnedFileIfPresent(_ relativePath: String) throws {
        let url = try ownedURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AnnotationExporter.ExportError.writeFailed("\(error)")
        }
    }
}
