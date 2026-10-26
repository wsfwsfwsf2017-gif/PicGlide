import Foundation
import CoreGraphics

public struct Ink: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }
}

// Coordinates stay in the oriented original image, even after a crop.
public enum EditOperation: Equatable, Sendable {
    case crop(CGRect)
    case mosaic([CGPoint], diameter: Double, blockSize: Double, patch: RenderedImage)
    case rectangle(CGRect, ink: Ink, width: Double)
    case pencil([CGPoint], ink: Ink, width: Double)
}

public struct EditHistory: Sendable {
    private var entries: [EditOperation] = []
    private var position = 0
    private var saved: [EditOperation] = []

    public init() {}
    public var operations: [EditOperation] { Array(entries.prefix(position)) }
    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < entries.count }
    public var operationToUndo: EditOperation? { canUndo ? entries[position - 1] : nil }
    public var operationToRedo: EditOperation? { canRedo ? entries[position] : nil }
    public var isDirty: Bool { operations != saved }

    public mutating func append(_ operation: EditOperation) {
        entries.removeSubrange(position...)
        entries.append(operation)
        position += 1
    }

    public mutating func undo() { if canUndo { position -= 1 } }
    public mutating func redo() { if canRedo { position += 1 } }
    public mutating func markSaved() { saved = operations }
    public mutating func restoreSaved() {
        entries = saved
        position = entries.count
    }

    public func bounds(in original: CGRect) -> CGRect {
        operations.reduce(original) { bounds, operation in
            if case let .crop(rect) = operation { return bounds.intersection(rect) }
            return bounds
        }
    }
}

public struct Viewport: Sendable {
    public var viewSize: CGSize
    public var imageBounds: CGRect
    public var scale: CGFloat
    public var pan: CGPoint

    public init(viewSize: CGSize = .zero, imageBounds: CGRect = .zero,
                scale: CGFloat = 1, pan: CGPoint = .zero) {
        self.viewSize = viewSize; self.imageBounds = imageBounds
        self.scale = scale; self.pan = pan
    }

    public var imageRect: CGRect {
        let size = CGSize(width: imageBounds.width * scale, height: imageBounds.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2 + pan.x,
                      y: (viewSize.height - size.height) / 2 + pan.y,
                      width: size.width, height: size.height)
    }

    public func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - imageRect.minX) / scale + imageBounds.minX,
                y: (viewPoint.y - imageRect.minY) / scale + imageBounds.minY)
    }

    public func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: (imagePoint.x - imageBounds.minX) * scale + imageRect.minX,
                y: (imagePoint.y - imageBounds.minY) * scale + imageRect.minY)
    }

    public mutating func fit(inset: CGFloat = 0) {
        guard imageBounds.width > 0, imageBounds.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }
        scale = min(max(1, viewSize.width - inset * 2) / imageBounds.width,
                    max(1, viewSize.height - inset * 2) / imageBounds.height)
        pan = .zero
    }

    public mutating func zoom(by factor: CGFloat, around point: CGPoint) {
        guard scale.isFinite, scale > 0, factor.isFinite, factor > 0 else { return }
        let anchor = imagePoint(from: point)
        scale = min(32, max(min(0.01, scale), scale * factor))
        let moved = viewPoint(from: anchor)
        pan.x += point.x - moved.x
        pan.y += point.y - moved.y
    }

    public mutating func changeBounds(to newBounds: CGRect) {
        let anchor = viewPoint(from: newBounds.origin)
        imageBounds = newBounds
        let moved = viewPoint(from: newBounds.origin)
        pan.x += anchor.x - moved.x
        pan.y += anchor.y - moved.y
    }
}
