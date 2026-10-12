import Foundation
import CoreGraphics
import ImageIO

public enum ImageFiles {
    public static func images(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { ImageFormat.supports($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    public static func save(image: CGImage, format: ImageFormat, to url: URL,
                            expected: FileFingerprint? = nil) throws -> FileFingerprint {
        let manager = FileManager.default
        if let expected, try FileFingerprint.read(url) != expected { throw PicGlideError.externallyChanged }
        if manager.fileExists(atPath: url.path), !manager.isWritableFile(atPath: url.path) {
            throw PicGlideError.readOnly
        }
        let directory = url.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: directory.path) else { throw PicGlideError.readOnly }
        let data = try ImageCodec.encode(image, format: format)
        let temporary = directory.appendingPathComponent(".picglide-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let validated = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              validated.width == image.width, validated.height == image.height
        else { throw PicGlideError.encodingFailed }
        if let expected, try FileFingerprint.read(url) != expected { throw PicGlideError.externallyChanged }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        return try FileFingerprint.read(url)
    }
}

public actor ImageLoader {
    private var cache: [URL: (FileFingerprint, RenderedImage)] = [:]
    private var folder: URL?
    private var listing: [URL] = []

    public init() {}

    public func load(_ inputURL: URL) throws -> (ImageMetadata, RenderedImage, [URL]) {
        let url = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let metadata = try ImageMetadata.read(url)
        let directory = url.deletingLastPathComponent()
        if folder != directory {
            listing = (try? ImageFiles.images(in: directory)) ?? [url]; folder = directory
        }
        if !listing.contains(url) { listing.append(url) }
        let frame: RenderedImage
        if let cached = cache[url], cached.0 == metadata.fingerprint { frame = cached.1 }
        else {
            frame = RenderedImage(image: try ImageCodec.decode(url, maxDimension: 2048), bounds: metadata.bounds)
            cache[url] = (metadata.fingerprint, frame)
        }
        if let index = listing.firstIndex(of: url) {
            let retained = Set(listing[max(0, index - 1)...min(listing.count - 1, index + 1)])
            cache = cache.filter { retained.contains($0.key) }
        }
        return (metadata, frame, listing)
    }

    public func preload(_ urls: [URL]) {
        for url in urls where cache[url] == nil {
            guard !Task.isCancelled,
                  let metadata = try? ImageMetadata.read(url),
                  let image = try? ImageCodec.decode(url, maxDimension: 2048) else { continue }
            cache[url] = (metadata.fingerprint, RenderedImage(image: image, bounds: metadata.bounds))
        }
        // Neighbour tasks can outlive navigation; do not retain stale folders.
        if cache.count > 3 { cache.removeAll() }
    }

    public func invalidate(_ inputURL: URL) {
        let url = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        cache.removeValue(forKey: url)
        if let folder, folder == url.deletingLastPathComponent(), let refreshed = try? ImageFiles.images(in: folder) {
            listing = refreshed
        }
    }
}
