import Foundation

public enum CropAdjustment: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .move: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    public func applying(to rect: CGRect, delta: CGPoint, within bounds: CGRect) -> CGRect {
        if self == .move {
            return CGRect(x: min(bounds.maxX - rect.width, max(bounds.minX, rect.minX + delta.x)),
                          y: min(bounds.maxY - rect.height, max(bounds.minY, rect.minY + delta.y)),
                          width: rect.width, height: rect.height)
        }
        var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        if self == .left || self == .topLeft || self == .bottomLeft {
            x0 = min(x1 - 1, max(bounds.minX, x0 + delta.x))
        }
        if self == .right || self == .topRight || self == .bottomRight {
            x1 = max(x0 + 1, min(bounds.maxX, x1 + delta.x))
        }
        if self == .top || self == .topLeft || self == .topRight {
            y0 = min(y1 - 1, max(bounds.minY, y0 + delta.y))
        }
        if self == .bottom || self == .bottomLeft || self == .bottomRight {
            y1 = max(y0 + 1, min(bounds.maxY, y1 + delta.y))
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
