import Foundation
import CoreGraphics
import ImageIO
import libwebp

public enum PicGlideError: LocalizedError {
    case unreadable, invalidImage, encodingFailed, unsupportedFormat, readOnly, externallyChanged, multiFrame

    public var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取图片，请确认文件存在且有读取权限。"
        case .invalidImage: "图片内容无效，或裁剪区域没有像素。"
        case .encodingFailed: "图片编码失败，原文件未被替换。"
        case .unsupportedFormat: "此格式无法保存，请另存为 PNG、JPEG 或 WebP。"
        case .readOnly: "文件或文件夹不可写，请选择其他位置另存。"
        case .externallyChanged: "原文件已被其他程序修改。请另存为，避免覆盖其他修改。"
        case .multiFrame: "此文件包含多个画面，第一版仅编辑首帧。请另存为静态图片。"
        }
    }
}

public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, webp, heic, bmp, tiff, gif

    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "bmp", "tif", "tiff", "gif"]
    public static let exportFormats: [ImageFormat] = [.png, .jpeg, .webp]

    public var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .webp: "org.webmproject.webp"
        case .heic: "public.heic"
        case .bmp: "com.microsoft.bmp"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        }
    }

    public static func from(type: String) -> ImageFormat? {
        if type == "public.heif" { return .heic }
        return allCases.first { $0.typeIdentifier == type }
    }

    public static func supports(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

public struct FileFingerprint: Equatable, Sendable {
    public let size: UInt64
    public let modificationDate: Date
    public let inode: UInt64

    public static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw PicGlideError.unreadable
        }
        return Self(size: size.uint64Value, modificationDate: date, inode: inode.uint64Value)
    }
}

public struct ImageMetadata: Sendable {
    public let url: URL
    public let pixelSize: CGSize
    public let typeIdentifier: String
    public let frameCount: Int
    public let fingerprint: FileFingerprint
    public var bounds: CGRect { CGRect(origin: .zero, size: pixelSize) }

    public static func read(_ url: URL) throws -> Self {
        let fingerprint = try FileFingerprint.read(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, ImageCodec.primaryFrameIndex(source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { throw PicGlideError.unreadable }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = (5...8).contains(orientation)
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return Self(url: url, pixelSize: size, typeIdentifier: type as String,
                    frameCount: CGImageSourceGetCount(source), fingerprint: fingerprint)
    }
}

public enum ImageCodec {
    static func primaryFrameIndex(_ source: CGImageSource) -> Int {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return index >= 0 && index < CGImageSourceGetCount(source) ? index : 0
    }

    public static func decode(_ url: URL, maxDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, primaryFrameIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxDimension),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PicGlideError.unreadable }
        return image
    }

    public static func encode(_ image: CGImage, format: ImageFormat) throws -> Data {
        if format == .webp { return try encodeWebP(image) }
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard supported.contains(format.typeIdentifier) else { throw PicGlideError.unsupportedFormat }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil)
        else { throw PicGlideError.encodingFailed }
        // Rebuild metadata instead of retaining unedited embedded previews.
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.95]
        var output = image
        if format == .jpeg || format == .heic {
            let context = try ImageRenderer.context(width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw PicGlideError.encodingFailed }
            output = flattened
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PicGlideError.encodingFailed }
        return data as Data
    }

    private static func encodeWebP(_ image: CGImage) throws -> Data {
        guard image.width <= 16383, image.height <= 16383 else { throw PicGlideError.encodingFailed }
        let context = try ImageRenderer.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let buffer = context.data else { throw PicGlideError.encodingFailed }
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        // libwebp expects straight RGBA; CGContext supplies premultiplied RGBA.
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let alpha = Int(bytes[offset + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 {
                    bytes[offset + channel] = UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let count = WebPEncodeLosslessRGBA(bytes, Int32(image.width), Int32(image.height),
                                         Int32(image.width * 4), &output)
        guard count > 0, let output else { throw PicGlideError.encodingFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: count)
    }
}
