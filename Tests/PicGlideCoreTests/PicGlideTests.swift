import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PicGlideCore

private func image(width: Int = 100, height: Int = 80, alpha: UInt8 = 255) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = (y * width + x) * 4
            bytes[p] = UInt8(x % 256) * (alpha == 255 ? 1 : 0)
            bytes[p + 1] = UInt8(y % 256) * (alpha == 255 ? 1 : 0)
            bytes[p + 2] = alpha; bytes[p + 3] = alpha
        }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func pixels(_ image: CGImage) throws -> [UInt8] {
    let context = try ImageRenderer.context(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height * 4))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("picglide-tests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func pointerAnchoredZoomAndCoordinateRoundTrip() {
    var viewport = Viewport(viewSize: CGSize(width: 900, height: 600),
        imageBounds: CGRect(x: 120, y: 70, width: 2000, height: 1200), scale: 0.3, pan: CGPoint(x: -30, y: 20))
    let pointer = CGPoint(x: 321, y: 234)
    let before = viewport.imagePoint(from: pointer)
    viewport.zoom(by: 1.7, around: pointer)
    let after = viewport.imagePoint(from: pointer)
    #expect(abs(before.x - after.x) < 0.000001)
    #expect(abs(before.y - after.y) < 0.000001)
    let roundTrip = viewport.viewPoint(from: after)
    #expect(abs(roundTrip.x - pointer.x) < 0.000001)
    #expect(abs(roundTrip.y - pointer.y) < 0.000001)
}

@Test func cropKeepsPositionAndUndoRestoresGeometry() {
    let original = CGRect(x: 0, y: 0, width: 1200, height: 900)
    var viewport = Viewport(viewSize: CGSize(width: 800, height: 600), imageBounds: original)
    viewport.fit()
    let crop = CGRect(x: 120, y: 80, width: 500, height: 400)
    let position = viewport.viewPoint(from: crop.origin)
    viewport.changeBounds(to: crop)
    #expect(viewport.viewPoint(from: crop.origin) == position)
    viewport.changeBounds(to: original)
    #expect(abs(viewport.pan.x) < 0.000001)
    #expect(abs(viewport.pan.y) < 0.000001)
}

@Test func undoRedoAndSavedBranches() {
    var history = EditHistory()
    let rect = CGRect(x: 5, y: 6, width: 30, height: 20)
    history.append(.crop(rect)); history.markSaved()
    #expect(!history.isDirty)
    history.undo(); #expect(history.isDirty)
    history.redo(); #expect(!history.isDirty)
    history.undo()
    history.append(.mosaic(rect, blockSize: 12))
    #expect(history.isDirty && !history.canRedo)
    history.undo(); history.redo()
    #expect(history.operations == [.mosaic(rect, blockSize: 12)])
}

@Test func cropThenDrawingUsesOriginalCoordinates() throws {
    let source = try image()
    let crop = CGRect(x: 20, y: 10, width: 60, height: 50)
    let red = Ink(red: 1, green: 0, blue: 0)
    let operations: [EditOperation] = [.crop(crop),
        .pencil([CGPoint(x: 25, y: 20), CGPoint(x: 50, y: 20)], ink: red, width: 6),
        .rectangle(CGRect(x: 30, y: 30, width: 20, height: 20), ink: red, width: 3)]
    let result = try ImageRenderer.render(source: source, originalBounds: CGRect(x: 0, y: 0, width: 100, height: 80), operations: operations)
    #expect(result.image.width == 60 && result.image.height == 50)
    #expect(result.bounds == crop)
    let bytes = try pixels(result.image)
    let strokePixel = (10 * 60 + 10) * 4
    #expect(bytes[strokePixel] > 240 && bytes[strokePixel + 1] < 10)
    let framePixel = (20 * 60 + 10) * 4
    #expect(bytes[framePixel] > 240 && bytes[framePixel + 1] < 10)
    let untouched = try ImageRenderer.render(source: source, originalBounds: CGRect(x: 0, y: 0, width: 100, height: 80), operations: [.crop(crop)])
    let croppedBytes = try pixels(untouched.image)
    #expect(croppedBytes[0] == 20 && croppedBytes[1] == 10)
}

@Test func mosaicStaysInsideSelectionAndUndoes() throws {
    let source = try image()
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
    let rect = CGRect(x: 20, y: 20, width: 40, height: 40)
    var history = EditHistory()
    history.append(.mosaic(rect, blockSize: 16))
    let result = try ImageRenderer.render(source: source, originalBounds: bounds, operations: history.operations)
    let original = try pixels(source), edited = try pixels(result.image)
    #expect(original.prefix(40) == edited.prefix(40))
    let inside = (25 * 100 + 25) * 4
    #expect(Array(original[inside..<inside + 3]) != Array(edited[inside..<inside + 3]))
    let adjacent = (25 * 100 + 26) * 4
    #expect(Array(edited[inside..<inside + 3]) == Array(edited[adjacent..<adjacent + 3]))
    history.undo()
    let restored = try ImageRenderer.render(source: source, originalBounds: bounds, operations: history.operations)
    #expect(try pixels(restored.image) == original)
    history.redo(); #expect(history.operations.count == 1)
}

@Test func everyToolCanUndoToOriginal() throws {
    let source = try image(), bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
    let ink = Ink(red: 1, green: 0, blue: 0, alpha: 0.5)
    let operations: [EditOperation] = [.crop(CGRect(x: 1, y: 1, width: 60, height: 40)),
        .mosaic(CGRect(x: 20, y: 20, width: 30, height: 30), blockSize: 12),
        .rectangle(CGRect(x: 10, y: 10, width: 50, height: 50), ink: ink, width: 5),
        .pencil([CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 60)], ink: ink, width: 8)]
    for operation in operations {
        var history = EditHistory(); history.append(operation)
        _ = try ImageRenderer.render(source: source, originalBounds: bounds, operations: history.operations)
        history.undo()
        #expect(try pixels(ImageRenderer.render(source: source, originalBounds: bounds, operations: history.operations).image) == pixels(source))
        history.redo(); #expect(history.operations == [operation])
    }
}

@Test func webPTransparencyRoundTrip() throws {
    let source = try image(width: 12, height: 9, alpha: 128)
    let data = try ImageCodec.encode(source, format: .webp)
    let cgSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(cgSource, 0, nil))
    #expect(decoded.width == 12 && decoded.height == 9)
    let bytes = try pixels(decoded)
    #expect(bytes[3] == 128)
    #expect(abs(Int(bytes[2]) - 128) <= 1)
    #expect(bytes[0] == 0 && bytes[1] == 0)
}

@Test func staticFormatsSaveAndReadBack() throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    for format in [ImageFormat.png, .jpeg, .webp, .heic, .bmp, .tiff, .gif] {
        let url = directory.appendingPathComponent("test.\(format.fileExtension)")
        try ImageFiles.save(image: image(), format: format, to: url)
        let metadata = try ImageMetadata.read(url)
        #expect(metadata.pixelSize == CGSize(width: 100, height: 80))
        #expect(metadata.frameCount == 1)
        #expect(ImageFormat.from(type: metadata.typeIdentifier) == format)
    }
}

@Test func externalModificationAndReadOnlyLeaveOriginalIntact() throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("original.png")
    try ImageFiles.save(image: image(), format: .png, to: url)
    let fingerprint = try FileFingerprint.read(url)
    let replacement = try ImageCodec.encode(image(width: 55), format: .png)
    try replacement.write(to: url)
    #expect(throws: PicGlideError.self) {
        try ImageFiles.save(image: image(width: 22), format: .png, to: url, expected: fingerprint)
    }
    #expect(try Data(contentsOf: url) == replacement)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    #expect(throws: PicGlideError.self) {
        try ImageFiles.save(image: image(width: 22), format: .png, to: url, expected: FileFingerprint.read(url))
    }
    #expect(try Data(contentsOf: url) == replacement)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["original.png"])
}

@Test func successfulOverwriteIsDecodable() throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("original.webp")
    try ImageFiles.save(image: image(), format: .webp, to: url)
    let before = try FileFingerprint.read(url)
    let after = try ImageFiles.save(image: image(width: 42, height: 31), format: .webp, to: url, expected: before)
    #expect(before != after)
    #expect(try ImageMetadata.read(url).pixelSize == CGSize(width: 42, height: 31))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["original.webp"])
}

@Test func orientedJPEGAndMultipleFrames() throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let jpg = directory.appendingPathComponent("rotated.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try image(width: 120, height: 80), [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    #expect(try ImageMetadata.read(jpg).pixelSize == CGSize(width: 80, height: 120))
    let decoded = try ImageCodec.decode(jpg, maxDimension: 120)
    #expect(decoded.width == 80 && decoded.height == 120)
    let gif = directory.appendingPathComponent("animation.gif")
    let animated = try #require(CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 2, nil))
    CGImageDestinationAddImage(animated, try image(), nil)
    CGImageDestinationAddImage(animated, try image(), nil)
    #expect(CGImageDestinationFinalize(animated))
    #expect(try ImageMetadata.read(gif).frameCount == 2)
}

@Test func thousandImageDirectoryNaturalOrder() throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<1000 { try Data().write(to: directory.appendingPathComponent("image\(index).png")) }
    try Data().write(to: directory.appendingPathComponent(".hidden.png"))
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
    let start = Date()
    let files = try ImageFiles.images(in: directory)
    print("Thousand-image listing: \(Date().timeIntervalSince(start)) seconds")
    #expect(files.count == 1000)
    #expect(files[2].lastPathComponent == "image2.png")
    #expect(files[10].lastPathComponent == "image10.png")
}

@Test func savingRefreshesFolderListingAndCachedPixels() async throws {
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("photo1.png")
    let next = directory.appendingPathComponent("photo2.png")
    let copy = directory.appendingPathComponent("photo3.png")
    try ImageFiles.save(image: image(), format: .png, to: first)
    try ImageFiles.save(image: image(), format: .png, to: next)
    let loader = ImageLoader()
    _ = try await loader.load(first)
    try ImageFiles.save(image: image(width: 42), format: .png, to: first)
    try ImageFiles.save(image: image(), format: .png, to: copy)
    await loader.invalidate(first)
    let (_, frame, files) = try await loader.load(first)
    #expect(frame.image.width == 42)
    #expect(files == [first, next, copy].map { $0.resolvingSymlinksInPath() })
}

@Test func readableImageOpensWithoutFolderListingPermission() async throws {
    let directory = try temporaryDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let url = directory.appendingPathComponent("selected.png")
    try ImageFiles.save(image: image(), format: .png, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: directory.path)
    let (_, frame, files) = try await ImageLoader().load(url)
    #expect(frame.image.width == 100)
    #expect(files.count == 1)
}
