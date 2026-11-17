import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PicGlideCore

private func drawingPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try ImageRenderer.context(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
}

private func drawingImage(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

@Test func canvasPresetsAndCustomSizesAreWhiteAndExact() throws {
    for (width, height) in [(1920, 1080), (2560, 1440), (19, 37), (1, 1)] {
        let size = try CanvasSize(width: width, height: height), image = try size.makeImage()
        #expect(image.width == width && image.height == height)
        let bytes = try drawingPixels(image)
        #expect(bytes.allSatisfy { $0 == 255 })
    }
}

@Test func invalidCanvasSizesAreRejectedBeforeAllocation() {
    for (width, height) in [(0, 1), (-1, 100), (8193, 1), (8192, 8192), (Int.max, Int.max)] {
        #expect(throws: DrawingError.self) { try CanvasSize(width: width, height: height) }
    }
}

@Test func fillUsesTopLeftPixelsFourNeighborsAndTransparency() throws {
    let red: [UInt8] = [255, 0, 0, 255], clear: [UInt8] = [0, 0, 0, 0]
    var bytes = Array(repeating: clear, count: 12).flatMap { $0 }
    bytes.replaceSubrange(0..<4, with: red)
    bytes.replaceSubrange(20..<24, with: red)
    let source = try drawingImage(width: 4, height: 3, pixels: bytes)
    let bounds = CGRect(x: 0, y: 0, width: 4, height: 3), blue = Ink(red: 0, green: 0, blue: 1)
    let mask = try #require(try ImageRenderer.fillMask(in: RenderedImage(image: source, bounds: bounds), at: .zero, ink: blue))
    #expect(mask.bounds == CGRect(x: 0, y: 0, width: 1, height: 1))
    let result = try ImageRenderer.render(source: source, originalBounds: bounds, operations: [.fill(mask: mask, ink: blue)])
    let actual = try drawingPixels(result.image)
    #expect(Array(actual[0..<4]) == [0, 0, 255, 255])
    #expect(Array(actual[20..<24]) == red)
    #expect(Array(actual[44..<48]) == clear)
}

@Test func fillToleranceStopsAtDifferentColorAndAlpha() throws {
    let source = try drawingImage(width: 4, height: 1,
        pixels: [200, 200, 200, 255, 212, 212, 212, 255, 220, 220, 220, 255, 200, 200, 200, 255])
    let frame = RenderedImage(image: source, bounds: CGRect(x: 0, y: 0, width: 4, height: 1))
    let mask = try #require(try ImageRenderer.fillMask(in: frame, at: .zero, ink: Ink(red: 1, green: 0, blue: 0)))
    #expect(mask.bounds.width == 2)
    let alphaSource = try drawingImage(width: 2, height: 1, pixels: [0, 0, 0, 0, 0, 0, 0, 80])
    let alphaMask = try #require(try ImageRenderer.fillMask(in: RenderedImage(image: alphaSource,
        bounds: CGRect(x: 0, y: 0, width: 2, height: 1)), at: .zero, ink: Ink(red: 0, green: 1, blue: 0)))
    #expect(alphaMask.bounds.width == 1)
}

@Test func fillStaysInsideClosedFrameAndIgnoresSameColor() throws {
    let size = try CanvasSize(width: 100, height: 80), source = try size.makeImage()
    let black = Ink(red: 0, green: 0, blue: 0), red = Ink(red: 1, green: 0, blue: 0)
    let rectangle = EditOperation.rectangle(CGRect(x: 20, y: 10, width: 50, height: 50), ink: black, width: 4)
    let framed = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: [rectangle])
    let mask = try #require(try ImageRenderer.fillMask(in: framed, at: CGPoint(x: 30, y: 20), ink: red))
    let result = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: [rectangle, .fill(mask: mask, ink: red)])
    let bytes = try drawingPixels(result.image)
    #expect(Array(bytes[(20 * 100 + 30) * 4..<(20 * 100 + 30) * 4 + 4]) == [255, 0, 0, 255])
    #expect(Array(bytes[0..<4]) == [255, 255, 255, 255])
    #expect(try ImageRenderer.fillMask(in: result, at: CGPoint(x: 30, y: 20), ink: red) == nil)
}

@Test func fillRejectsPreviewAndOutOfBoundsCoordinates() throws {
    let source = try CanvasSize(width: 10, height: 8).makeImage(), ink = Ink(red: 0, green: 0, blue: 0)
    let frame = RenderedImage(image: source, bounds: CGRect(x: 0, y: 0, width: 10, height: 8))
    for point in [CGPoint(x: -1, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: CGFloat.nan, y: 0)] {
        #expect(throws: PicGlideError.self) { try ImageRenderer.fillMask(in: frame, at: point, ink: ink) }
    }
    #expect(throws: PicGlideError.self) {
        try ImageRenderer.fillMask(in: RenderedImage(image: source, bounds: CGRect(x: 0, y: 0, width: 100, height: 80)), at: .zero, ink: ink)
    }
}

@Test func fillHonorsCancellation() async throws {
    let size = try CanvasSize(width: 1920, height: 1080)
    let frame = try RenderedImage(image: size.makeImage(), bounds: size.bounds)
    let task = Task {
        try await Task.sleep(for: .milliseconds(10))
        return try ImageRenderer.fillMask(in: frame, at: .zero, ink: Ink(red: 1, green: 0, blue: 0))
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Canceled fill returned a mask") }
    catch is CancellationError {} catch { throw error }
}

@Test func fullHDCanvasFillCoversEveryPixel() throws {
    let size = try CanvasSize(width: 1920, height: 1080), source = try size.makeImage()
    let frame = RenderedImage(image: source, bounds: size.bounds), black = Ink(red: 0, green: 0, blue: 0)
    let started = Date()
    let mask = try #require(try ImageRenderer.fillMask(in: frame, at: CGPoint(x: 100, y: 100), ink: black))
    #expect(mask.bounds == size.bounds)
    let result = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: [.fill(mask: mask, ink: black)])
    let bytes = try drawingPixels(result.image)
    #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy {
        bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 && bytes[$0 + 3] == 255
    })
    print("Full HD fill and verification seconds:", Date().timeIntervalSince(started))
}

@Test func chineseTextRendersColorMultilineAndBold() throws {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 300), blue = Ink(red: 0, green: 0, blue: 1)
    let regular = try ImageRenderer.textPatch("你好 PicGlide", at: .zero, within: bounds, fontSize: 32, bold: false, ink: blue)
    let bold = try ImageRenderer.textPatch("你好 PicGlide", at: .zero, within: bounds, fontSize: 32, bold: true, ink: blue)
    let multiline = try ImageRenderer.textPatch("你好\nPicGlide", at: .zero, within: bounds, fontSize: 32, bold: false, ink: blue)
    let bytes = try drawingPixels(regular.image)
    #expect(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0 + 2] > 0 && bytes[$0] == 0 && bytes[$0 + 3] > 0 })
    let regularCoverage = stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    let boldBytes = try drawingPixels(bold.image)
    let boldCoverage = stride(from: 3, to: boldBytes.count, by: 4).reduce(0) { $0 + Int(boldBytes[$1]) }
    #expect(boldCoverage > regularCoverage)
    #expect(multiline.bounds.height > regular.bounds.height)
}

@Test func allColoredToolsKeepOpacityThroughLosslessExport() throws {
    let size = try CanvasSize(width: 100, height: 80)
    let source = try drawingImage(width: 100, height: 80, pixels: Array(repeating: 0, count: 100 * 80 * 4))
    let ink = Ink(red: 1, green: 0, blue: 0, alpha: 0.4)
    let frame = RenderedImage(image: source, bounds: size.bounds)
    let mask = try #require(try ImageRenderer.fillMask(in: frame, at: .zero, ink: ink))
    let text = try ImageRenderer.textPatch("字", at: CGPoint(x: 5, y: 5), within: size.bounds,
        fontSize: 32, bold: true, ink: ink)
    let operations: [EditOperation] = [.fill(mask: mask, ink: ink), .text(patch: text),
        .pencil([CGPoint(x: 40, y: 40)], ink: ink, width: 16),
        .rectangle(CGRect(x: 20, y: 20, width: 50, height: 40), ink: ink, width: 8)]
    for operation in operations {
        let rendered = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: [operation])
        let pixels = try drawingPixels(rendered.image)
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        #expect(alpha.max() == 102)
        for format in [ImageFormat.png, .webp] {
            let data = try ImageCodec.encode(rendered.image, format: format)
            let encoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            #expect(try drawingPixels(decoded) == pixels)
        }
    }
}

@Test func textFitsAtEdgesAndRejectsInvalidInput() throws {
    let bounds = CGRect(x: 20, y: 30, width: 400, height: 200)
    let rect = try ImageRenderer.textBounds("Hello", at: CGPoint(x: 419, y: 229), within: bounds, fontSize: 32, bold: false)
    #expect(bounds.contains(rect))
    for text in ["", " \n"] {
        #expect(throws: DrawingError.self) { try ImageRenderer.textBounds(text, at: bounds.origin, within: bounds, fontSize: 32, bold: false) }
    }
    for size in [0.0, 7, 513, .nan, .infinity, 12.5] {
        #expect(throws: DrawingError.self) { try ImageRenderer.textBounds("字", at: bounds.origin, within: bounds, fontSize: size, bold: false) }
    }
    #expect(throws: DrawingError.self) { try ImageRenderer.textBounds("放不下", at: .zero,
        within: CGRect(x: 0, y: 0, width: 10, height: 10), fontSize: 32, bold: false) }
}

@Test func croppedFillAndTextReplayThroughUndoRedoAndLosslessExport() throws {
    let size = try CanvasSize(width: 400, height: 300), source = try size.makeImage()
    let crop = CGRect(x: 80, y: 40, width: 300, height: 220), red = Ink(red: 1, green: 0, blue: 0)
    let cropped = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: [.crop(crop)])
    let mask = try #require(try ImageRenderer.fillMask(in: cropped, at: crop.origin, ink: red))
    #expect(mask.bounds == crop)
    let text = try ImageRenderer.textPatch("画板\nCanvas", at: CGPoint(x: 90, y: 50), within: crop,
        fontSize: 24, bold: true, ink: Ink(red: 0, green: 0, blue: 1))
    let operations: [EditOperation] = [.crop(crop), .fill(mask: mask, ink: red), .text(patch: text),
        .pencil([CGPoint(x: 100, y: 200)], ink: red, width: 6), .rectangle(crop.insetBy(dx: 2, dy: 2), ink: red, width: 2)]
    var history = EditHistory()
    for operation in operations { history.append(operation) }
    for _ in operations { history.undo() }
    #expect(history.operations.isEmpty)
    for _ in operations { history.redo() }
    #expect(history.operations == operations)
    let full = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: history.operations)
    let preview = try ImageRenderer.render(source: source, originalBounds: size.bounds, operations: history.operations, maxDimension: 200)
    #expect(full.bounds == crop && preview.bounds == crop)
    let previewBytes = try drawingPixels(preview.image)
    #expect(Array(previewBytes.suffix(4)) == [255, 0, 0, 255])
    history.markSaved(); history.append(.text(patch: text)); history.restoreSaved()
    #expect(history.operations == operations && !history.canRedo && !history.isDirty)
    for format in [ImageFormat.png, .webp] {
        let data = try ImageCodec.encode(full.image, format: format)
        let encoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        #expect(decoded.width == 300 && decoded.height == 220)
        #expect(try drawingPixels(decoded) == drawingPixels(full.image))
    }
}
