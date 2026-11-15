import CoreGraphics
import Foundation
import ImageIO
import StudioCore
import UniformTypeIdentifiers

/// Where a mask's derived raster lives. The project file carries the mask's
/// geometry and a reference; these bytes are a cache, and losing them costs a
/// recomputation and never the mask.
enum MaskStore {
    /// Tests point this at a scratch directory so a check never writes into the
    /// store belonging to the app the owner is working in.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("RetouchStudio/AI/masks", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Writes the raster under the mask's id in one step and returns the
    /// reference to store in the project. The staging folder is removed on
    /// failure, so a mask never points at half a file.
    static func adopt(id: UUID, image: CGImage) throws -> MaskRasterReference {
        let manager = FileManager.default
        let destination = folder(for: id)
        let staging = root.appendingPathComponent(".\(id.uuidString).staging",
                                                  isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFile = staging.appendingPathComponent("mask.png")
        do {
            try writePNG(image, to: stagedFile)
            let digest = try AIRuntime.sha256(of: stagedFile)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staging, to: destination)
            return MaskRasterReference(file: "mask.png", sha256: digest,
                                       width: image.width, height: image.height)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The raster the reference names, or nil when the file is gone or no
    /// longer matches its digest. A nil answer is the caller's signal to draw
    /// the mask from its geometry, never to apply unknown pixels.
    static func load(_ reference: MaskRasterReference, id: UUID) -> CGImage? {
        let url = folder(for: id).appendingPathComponent(reference.file)
        guard FileManager.default.fileExists(atPath: url.path),
              let digest = try? AIRuntime.sha256(of: url),
              digest.lowercased() == reference.sha256.lowercased(),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == reference.width, image.height == reference.height else {
            return nil
        }
        return image
    }

    static func remove(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
