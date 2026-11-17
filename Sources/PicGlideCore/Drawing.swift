import Foundation
import CoreGraphics
import CoreText

public enum DrawingError: LocalizedError {
    case invalidCanvasSize, emptyText, invalidFontSize, textDoesNotFit

    public var errorDescription: String? {
        switch self {
        case .invalidCanvasSize: "宽高需为 1–8192 的整数，总像素不能超过 3200 万。"
        case .emptyText: "请输入文字。"
        case .invalidFontSize: "字号需为 8–512 的整数。"
        case .textDoesNotFit: "文字超出画布，请减小字号或缩短内容。"
        }
    }
}

public struct CanvasSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    public init(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 32_000_000
        else { throw DrawingError.invalidCanvasSize }
        self.width = width; self.height = height
    }

    public func makeImage() throws -> CGImage {
        let context = try ImageRenderer.context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        guard let image = context.makeImage() else { throw PicGlideError.invalidImage }
        return image
    }
}

extension ImageRenderer {
    public static func fillMask(in frame: RenderedImage, at point: CGPoint, ink: Ink) throws -> RenderedImage? {
        guard point.x.isFinite, point.y.isFinite, frame.bounds.contains(point), valid(ink),
              frame.bounds.width == CGFloat(frame.image.width), frame.bounds.height == CGFloat(frame.image.height)
        else { throw PicGlideError.invalidImage }
        try Task.checkCancellation()
        let width = frame.image.width, height = frame.image.height
        let bitmap = try context(width: width, height: height)
        bitmap.setBlendMode(.copy)
        bitmap.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = bitmap.data else { throw PicGlideError.invalidImage }
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        let x = Int(floor(point.x - frame.bounds.minX)), y = Int(floor(point.y - frame.bounds.minY))
        let start = y * width + x, offset = start * 4
        let seed = (0..<4).map { Int(pixels[offset + $0]) }
        let target = [ink.red * ink.alpha, ink.green * ink.alpha, ink.blue * ink.alpha, ink.alpha]
            .map { Int(($0 * 255).rounded()) }
        if seed == target { return nil }
        let selected = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        selected.initialize(repeating: 0, count: width * height)
        defer { selected.deallocate() }
        func matches(_ index: Int) -> Bool {
            selected[index] == 0 && (0..<4).allSatisfy { abs(Int(pixels[index * 4 + $0]) - seed[$0]) <= 16 }
        }
        var stack = [start], minX = x, maxX = x, minY = y, maxY = y
        while let index = stack.popLast() {
            try Task.checkCancellation()
            guard matches(index) else { continue }
            let row = index / width
            var left = index % width, right = left
            while left > 0 && matches(row * width + left - 1) { left -= 1 }
            while right + 1 < width && matches(row * width + right + 1) { right += 1 }
            for column in left...right { selected[row * width + column] = 255 }
            minX = min(minX, left); maxX = max(maxX, right); minY = min(minY, row); maxY = max(maxY, row)
            for neighbor in [row - 1, row + 1] where neighbor >= 0 && neighbor < height {
                var column = left
                while column <= right {
                    if matches(neighbor * width + column) {
                        stack.append(neighbor * width + column)
                        repeat { column += 1 } while column <= right && matches(neighbor * width + column)
                    } else { column += 1 }
                }
            }
        }
        try Task.checkCancellation()
        let maskWidth = maxX - minX + 1, maskHeight = maxY - minY + 1
        guard let mask = CGContext(data: nil, width: maskWidth, height: maskHeight,
            bitsPerComponent: 8, bytesPerRow: maskWidth, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = mask.data else { throw PicGlideError.invalidImage }
        let output = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<maskHeight {
            output.advanced(by: row * mask.bytesPerRow).update(from: selected.advanced(by: (row + minY) * width + minX), count: maskWidth)
        }
        guard let image = mask.makeImage() else { throw PicGlideError.invalidImage }
        return RenderedImage(image: image, bounds: CGRect(x: frame.bounds.minX + CGFloat(minX),
            y: frame.bounds.minY + CGFloat(minY), width: CGFloat(maskWidth), height: CGFloat(maskHeight)))
    }

    public static func textBounds(_ text: String, at point: CGPoint, within bounds: CGRect,
                                  fontSize: Double, bold: Bool) throws -> CGRect {
        try layoutText(text, fontSize: fontSize, bold: bold).placed(at: point, within: bounds)
    }

    public static func textPatch(_ text: String, at point: CGPoint, within bounds: CGRect,
                                 fontSize: Double, bold: Bool, ink: Ink) throws -> RenderedImage {
        guard valid(ink) else { throw PicGlideError.invalidImage }
        let layout = try layoutText(text, fontSize: fontSize, bold: bold)
        let placed = try layout.placed(at: point, within: bounds)
        let bitmap = try context(width: Int(placed.width), height: Int(placed.height))
        bitmap.setFillColor(ink.cgColor)
        bitmap.textMatrix = .identity
        for (index, line) in layout.lines.enumerated() {
            bitmap.textPosition = CGPoint(x: 2 - layout.left, y: placed.height - 2 - layout.ascent - CGFloat(index) * layout.lineHeight)
            CTLineDraw(line, bitmap)
        }
        guard let image = bitmap.makeImage() else { throw PicGlideError.invalidImage }
        return RenderedImage(image: image, bounds: placed)
    }

    private static func valid(_ ink: Ink) -> Bool {
        [ink.red, ink.green, ink.blue, ink.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    private struct TextLayout {
        let lines: [CTLine]
        let size: CGSize
        let ascent: CGFloat
        let left: CGFloat
        let lineHeight: CGFloat

        func placed(at point: CGPoint, within bounds: CGRect) throws -> CGRect {
            guard point.x.isFinite, point.y.isFinite, bounds.contains(point),
                  size.width <= bounds.width, size.height <= bounds.height else { throw DrawingError.textDoesNotFit }
            return CGRect(x: min(max(point.x.rounded(), bounds.minX), bounds.maxX - size.width),
                y: min(max(point.y.rounded(), bounds.minY), bounds.maxY - size.height), width: size.width, height: size.height)
        }
    }

    private static func layoutText(_ text: String, fontSize: Double, bold: Bool) throws -> TextLayout {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DrawingError.emptyText }
        guard fontSize.isFinite, fontSize.rounded() == fontSize, (8...512).contains(fontSize)
        else { throw DrawingError.invalidFontSize }
        let base = CTFontCreateUIFontForLanguage(.system, fontSize, "zh-Hans" as CFString)!
        let font = bold ? CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) ?? base : base
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        var left: CGFloat = 0, right: CGFloat = 0, ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        for line in lines {
            var a: CGFloat = 0, d: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line, &a, &d, nil)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ascent = max(ascent, a, ink.isNull ? 0 : ink.maxY)
            descent = max(descent, d, ink.isNull ? 0 : -ink.minY)
            if !ink.isNull { left = min(left, ink.minX); right = max(right, ink.maxX) }
            right = max(right, advance)
        }
        let lineHeight = ceil(ascent + descent + max(CTFontGetLeading(font), fontSize * 0.15))
        return TextLayout(lines: lines, size: CGSize(width: max(1, ceil(right - left) + 4),
            height: ceil(ascent + descent + CGFloat(lines.count - 1) * lineHeight) + 4),
            ascent: ascent, left: left, lineHeight: lineHeight)
    }
}
