import Foundation
import CoreGraphics
import CoreImage
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
            case let .mosaic(rect, blockSize):
                let region = localRect(rect.intersection(bounds)).integral.intersection(
                    CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard !region.isEmpty else { continue }
                let ciRect = CGRect(x: region.minX, y: CGFloat(image.height) - region.maxY,
                                    width: region.width, height: region.height)
                let filter = CIFilter.pixellate()
                filter.inputImage = CIImage(cgImage: image)
                filter.scale = Float(max(1, blockSize * sx))
                filter.center = .zero
                guard let result = filter.outputImage,
                      let patch = ciContext.createCGImage(result.cropped(to: ciRect), from: ciRect)
                else { throw PicGlideError.invalidImage }
                context.draw(patch, in: ciRect)
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
