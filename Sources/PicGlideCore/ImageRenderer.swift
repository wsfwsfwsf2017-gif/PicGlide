import Foundation
import CoreGraphics
// CIContext supports concurrent rendering; older SDKs omit its Sendable annotation.
@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins

public struct RenderedImage: @unchecked Sendable {
    public let image: CGImage
    public let bounds: CGRect
    public init(image: CGImage, bounds: CGRect) { self.image = image; self.bounds = bounds }
}

public enum ImageRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    public static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PicGlideError.invalidImage }
        return context
    }

    public static func mosaicPath(_ points: [CGPoint], diameter: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, diameter.isFinite, diameter > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return path }
        if points.allSatisfy({ $0 == first }) {
            path.addEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                                      width: diameter, height: diameter))
            return path
        }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path.copy(strokingWithWidth: diameter, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    public static func mosaicImage(_ frame: RenderedImage, blockSize: Double) throws -> CGImage {
        guard blockSize.isFinite, blockSize > 0 else { throw PicGlideError.invalidImage }
        let sx = CGFloat(frame.image.width) / frame.bounds.width
        let sy = CGFloat(frame.image.height) / frame.bounds.height
        let filter = CIFilter.pixellate()
        filter.inputImage = CIImage(cgImage: frame.image).clampedToExtent()
        filter.scale = Float(max(1, blockSize * sx))
        // Keep the pixel grid anchored in the original image across crops and preview resolutions.
        filter.center = CGPoint(x: -frame.bounds.minX * sx, y: CGFloat(frame.image.height) + frame.bounds.minY * sy)
        let extent = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        guard let result = filter.outputImage, let image = ciContext.createCGImage(result, from: extent)
        else { throw PicGlideError.invalidImage }
        return image
    }

    public static func render(source: CGImage, originalBounds: CGRect,
                              operations: [EditOperation], maxDimension: Int? = nil) throws -> RenderedImage {
        var image = source
        var bounds = originalBounds
        if let maxDimension, max(source.width, source.height) > maxDimension {
            let factor = CGFloat(maxDimension) / CGFloat(max(source.width, source.height))
            let context = try context(width: max(1, Int(CGFloat(source.width) * factor)),
                                      height: max(1, Int(CGFloat(source.height) * factor)))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            guard let scaled = context.makeImage() else { throw PicGlideError.invalidImage }
            image = scaled
        }
        for operation in operations {
            try Task.checkCancellation()
            let sx = CGFloat(image.width) / bounds.width
            let sy = CGFloat(image.height) / bounds.height
            func localRect(_ rect: CGRect) -> CGRect {
                CGRect(x: (rect.minX - bounds.minX) * sx, y: (rect.minY - bounds.minY) * sy,
                       width: rect.width * sx, height: rect.height * sy)
            }
            if case let .crop(rect) = operation {
                let croppedBounds = bounds.intersection(rect.integral)
                guard !croppedBounds.isEmpty, !croppedBounds.isNull,
                      let cropped = image.cropping(to: localRect(croppedBounds).integral)
                else { throw PicGlideError.invalidImage }
                image = cropped; bounds = croppedBounds
                continue
            }
            let context = try context(width: image.width, height: image.height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            switch operation {
            case let .mosaic(points, diameter, blockSize):
                guard diameter.isFinite, diameter > 0,
                      points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw PicGlideError.invalidImage }
                let mask = mosaicPath(points, diameter: diameter)
                guard !mask.isEmpty, mask.boundingBoxOfPath.intersects(bounds) else { continue }
                let patch = try mosaicImage(RenderedImage(image: image, bounds: bounds), blockSize: blockSize)
                var transform = CGAffineTransform(a: sx, b: 0, c: 0, d: -sy,
                                                  tx: -bounds.minX * sx, ty: CGFloat(image.height) + bounds.minY * sy)
                context.addPath(mask.copy(using: &transform)!)
                context.clip()
                context.setBlendMode(.copy)
                context.draw(patch, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            case let .rectangle(rect, ink, width):
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: sx, y: -sy)
                context.setStrokeColor(ink.cgColor)
                context.setLineWidth(width)
                context.stroke(rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
            case let .pencil(points, ink, width):
                guard let first = points.first else { continue }
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: sx, y: -sy)
                context.setStrokeColor(ink.cgColor)
                context.setFillColor(ink.cgColor)
                context.setLineWidth(width)
                context.setLineCap(.round); context.setLineJoin(.round)
                if points.count == 1 {
                    context.fillEllipse(in: CGRect(x: first.x - bounds.minX - width / 2,
                        y: first.y - bounds.minY - width / 2, width: width, height: width))
                } else {
                    context.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
                    for point in points.dropFirst() {
                        context.addLine(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
                    }
                    context.strokePath()
                }
            case .crop: break
            }
            guard let rendered = context.makeImage() else { throw PicGlideError.invalidImage }
            image = rendered
        }
        return RenderedImage(image: image, bounds: bounds)
    }
}
