import Foundation
import AppKit
import CoreGraphics

/// Encodes a composite `CGImage` to PNG bytes.
///
/// Deliberately not `NSImage.pngData()`, the app's existing encoder
/// (`PanelMask.swift:3-10`): that round-trips through TIFF and through
/// `NSImage.size`, which is in points, so a Retina composite comes back at half
/// its pixel dimensions. `NSBitmapImageRep(cgImage:)` takes the pixel grid
/// directly.
///
/// No `lockFocus`: it needs the main thread and an active graphics context, and
/// export runs off the main actor.
public enum AnnotationExporter {

    public enum ExportError: Error, Equatable {
        case encodeFailed
        case writeFailed(String)
        case notOwnedPath(String)
    }

    public static func pngData(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        // Explicit, because the rep otherwise reports its size in points and a
        // consumer reading `size` would see half the pixels on Retina.
        rep.size = NSSize(width: image.width, height: image.height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.encodeFailed
        }
        return data
    }

    /// Atomically replace a stored image, refusing anything outside
    /// `Remarc/images`.
    ///
    /// Both sides are resolved through `standardizedFileURL` and
    /// `resolvingSymlinksInPath()` before comparison, so `..` traversal and a
    /// symlinked images directory both land on the real path rather than on a
    /// string that merely looks contained.
    public static func replaceOwnedImage(at relativePath: String, with image: CGImage) throws {
        try replaceOwnedData(try pngData(from: image), at: relativePath)
    }

    /// The same replacement, given bytes the caller already encoded.
    ///
    /// Exists so Apply can fingerprint exactly the bytes it commits without
    /// encoding the image twice, and without the risk that a second encode
    /// produces something subtly different from what landed on disk.
    public static func replaceOwnedData(_ data: Data, at relativePath: String) throws {
        let imagesDir = remarcAppSupportURL
            .appendingPathComponent("images", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let target = resolveImagePath(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()

        guard target.pathComponents.count == imagesDir.pathComponents.count + 1,
              target.deletingLastPathComponent().path == imagesDir.path else {
            throw ExportError.notOwnedPath(relativePath)
        }

        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw ExportError.writeFailed("\(error)")
        }
    }

    /// Write a fresh PNG under `Remarc/images` and return its relative path.
    public static func writeNewImage(_ image: CGImage) throws -> String {
        let imagesDir = remarcAppSupportURL.appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: imagesDir.path) {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
        let relativePath = "images/\(UUID().uuidString).png"
        let data = try pngData(from: image)
        do {
            try data.write(to: resolveImagePath(relativePath), options: .atomic)
        } catch {
            throw ExportError.writeFailed("\(error)")
        }
        return relativePath
    }

    /// Decode at exact pixel dimensions. `NSImage(contentsOf:)` reports points and
    /// defers decoding, which is the wrong basis for a source-pixel coordinate
    /// system.
    public static func decode(relativePath: String) -> CGImage? {
        let url = resolveImagePath(relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: true
        ] as CFDictionary)
    }
}

/// Runtime-only monotonic revision per stored image path.
///
/// Thumbnails call `loadScreenshotImage` straight from `body` and there is no
/// revision state anywhere, so an applied annotation would keep showing the old
/// bytes until the view happened to be rebuilt from scratch. Not serialized: it
/// means nothing across launches.
@MainActor
public final class StoredImageRevisionCenter: ObservableObject {
    public static let shared = StoredImageRevisionCenter()

    @Published public private(set) var revisions: [String: Int] = [:]

    private init() {}

    public func revision(for relativePath: String) -> Int {
        revisions[relativePath] ?? 0
    }

    /// Called only after a successful atomic replacement.
    public func bump(_ relativePath: String) {
        revisions[relativePath, default: 0] += 1
    }
}
