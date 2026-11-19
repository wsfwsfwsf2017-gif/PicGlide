import Foundation
import CoreGraphics

public struct TextOverlay {
    private enum Entry {
        case text(UUID)
        case mask(CGPath)
    }

    public let annotations: [UUID: TextAnnotation]
    public let order: [UUID]
    private let entries: [Entry]

    public init(_ operations: [EditOperation]) {
        var annotations: [UUID: TextAnnotation] = [:]
        for case let .text(id, annotation) in operations { annotations[id] = annotation }
        self.annotations = annotations

        var order: [UUID] = []
        var entries: [Entry] = []
        var seen: Set<UUID> = []
        if !annotations.isEmpty {
            for operation in operations {
                switch operation {
                case let .text(id, _) where annotations[id] != nil && seen.insert(id).inserted:
                    order.append(id)
                    entries.append(.text(id))
                case let .mosaic(points, diameter, _, _) where !order.isEmpty:
                    entries.append(.mask(ImageRenderer.mosaicPath(points, diameter: diameter)))
                default: break
                }
            }
        }
        self.order = order
        self.entries = entries
    }

    public func hit(at point: CGPoint, within bounds: CGRect, padding: CGFloat = 0) -> UUID? {
        guard bounds.contains(point) else { return nil }
        for entry in entries.reversed() {
            switch entry {
            case let .mask(path) where path.contains(point):
                return nil
            case let .text(id):
                if let rect = annotations[id]?.patch.bounds.intersection(bounds), !rect.isEmpty,
                   rect.insetBy(dx: -padding, dy: -padding).contains(point) { return id }
            default: break
            }
        }
        return nil
    }

    public func draw(in context: CGContext, bounds: CGRect, transform: CGAffineTransform,
                     hiding hidden: UUID? = nil, replacing replacement: (id: UUID, patch: RenderedImage)? = nil,
                     liveMask: CGPath? = nil) {
        guard !entries.isEmpty else { return }
        context.saveGState()
        context.concatenate(transform)
        context.clip(to: bounds)
        let masksText = entries.count != order.count || liveMask != nil
        // Erase from an isolated overlay so a mosaic stroke cannot erase the pixels beneath the text.
        if masksText { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        func erase(_ path: CGPath) {
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        for entry in entries {
            switch entry {
            case let .mask(path): erase(path)
            case let .text(id) where id != hidden:
                guard let patch = replacement?.id == id ? replacement?.patch : annotations[id]?.patch,
                      bounds.intersects(patch.bounds) else { continue }
                context.saveGState()
                context.translateBy(x: patch.bounds.minX, y: patch.bounds.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(patch.image, in: CGRect(origin: .zero, size: patch.bounds.size))
                context.restoreGState()
            default: break
            }
        }
        if let liveMask { erase(liveMask) }
        if masksText { context.endTransparencyLayer() }
        context.restoreGState()
    }
}
