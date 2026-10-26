import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PicGlideCore

private func automationFixture() throws -> (URL, CGImage) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picglide-agent-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let context = try ImageRenderer.context(width: 120, height: 100)
    for y in 0..<100 {
        for x in 0..<120 {
            context.setFillColor(CGColor(red: CGFloat(x) / 120, green: CGFloat(y) / 100, blue: 0.3, alpha: 0.6))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let image = try #require(context.makeImage())
    try ImageFiles.save(image: image, format: .png, to: directory.appendingPathComponent("源图.png"))
    return (directory, image)
}

private func automationRequest(_ directory: URL, operations: [[String: Any]], output: String = "result.png") throws -> AutomationRequest {
    try AutomationRequest(data: JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
        "input": directory.appendingPathComponent("源图.png").path,
        "output": directory.appendingPathComponent(output).path, "operations": operations]))
}

private func automationPixels(_ image: CGImage) throws -> Data {
    let context = try ImageRenderer.context(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
}

@Test func agentCropCoordinatesAndDrawingMatchCore() throws {
    let (directory, original) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let operations: [[String: Any]] = [
        ["type": "crop", "x": 30, "y": 20, "width": 70, "height": 60],
        ["type": "rectangle", "x": 10, "y": 12, "width": 35, "height": 25, "color": "#FF0000", "lineWidth": 3],
        ["type": "pencil", "points": [["x": 5, "y": 7], ["x": 50, "y": 40]], "lineWidth": 2, "color": "#0000FF", "opacity": 0.5]
    ]
    let request = try automationRequest(directory, operations: operations)
    let rendered = try request.execute()
    let decoded = try ImageCodec.decode(request.input, maxDimension: 120)
    let expected = try ImageRenderer.render(source: decoded, originalBounds: CGRect(x: 0, y: 0, width: 120, height: 100), operations: [
        .crop(CGRect(x: 30, y: 20, width: 70, height: 60)),
        .rectangle(CGRect(x: 40, y: 32, width: 35, height: 25), ink: Ink(red: 1, green: 0, blue: 0), width: 3),
        .pencil([CGPoint(x: 35, y: 27), CGPoint(x: 80, y: 60)], ink: Ink(red: 0, green: 0, blue: 1, alpha: 0.5), width: 2)
    ])
    #expect(rendered.image.width == 70 && rendered.image.height == 60)
    #expect(try automationPixels(rendered.image) == automationPixels(expected.image))
    #expect(try automationPixels(original) == automationPixels(ImageCodec.decode(request.input, maxDimension: 120)))
}

@Test func agentMosaicAfterCropKeepsTransparencyThroughWebP() throws {
    let (directory, _) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = try automationRequest(directory, operations: [
        ["type": "crop", "x": 20, "y": 10, "width": 80, "height": 70],
        ["type": "mosaic", "points": [["x": 20, "y": 30], ["x": 60, "y": 30]]]
    ], output: "result.webp")
    let rendered = try request.execute()
    let decoded = try ImageCodec.decode(request.output, maxDimension: 120)
    #expect(decoded.width == 80 && decoded.height == 70)
    #expect(try automationPixels(decoded) == automationPixels(rendered.image))
    let bytes = try automationPixels(decoded)
    #expect(bytes[(30 * 80 + 40) * 4 + 3] == 153)
}

@Test func agentRejectsInvalidRequestsWithoutWriting() throws {
    let (directory, _) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let invalid: [[[String: Any]]] = [
        [["type": "crop", "x": 0, "y": 0, "width": 121, "height": 100]],
        [["type": "crop", "x": 0.5, "y": 0, "width": 20, "height": 20]],
        [["type": "crop", "x": 30, "y": 10, "width": -20, "height": 20]],
        [["type": "rectangle", "x": 30, "y": 10, "width": -20, "height": 20]],
        [["type": "mosaic", "points": []]],
        [["type": "mosaic", "points": [["x": 10, "y": 10]], "diameter": 2]],
        [["type": "mosaic", "points": [["x": true, "y": 10]]]],
        [["type": "pencil", "points": [["x": 150, "y": 10]]]],
        [["type": "pencil", "points": [["x": 10, "y": 10]], "color": "red"]],
        [["type": "rectangle", "x": 1, "y": 1, "width": 10, "height": 10, "opacity": 2]],
        [["type": "rotate"]], [["type": "crop", "x": 1, "y": 1, "width": 10, "height": 10, "typo": 1]]
    ]
    for operations in invalid {
        #expect(throws: AutomationError.self) { try automationRequest(directory, operations: operations).execute() }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.png").path))
    }
    #expect(throws: AutomationError.self) { try AutomationRequest(data: Data("{\"schemaVersion\":true}".utf8)) }
}

@Test func agentDoesNotReplaceExistingFilesOrDanglingSymlinks() throws {
    let (directory, _) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("源图.png"), before = try Data(contentsOf: input)
    #expect(throws: AutomationError.self) { try automationRequest(directory, operations: [], output: "源图.png").execute() }
    let target = directory.appendingPathComponent("result.png"), data = Data("keep me".utf8)
    try data.write(to: target)
    #expect(throws: AutomationError.self) { try automationRequest(directory, operations: []).execute() }
    #expect(try Data(contentsOf: target) == data)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: directory.appendingPathComponent("missing.png").path)
    #expect(throws: AutomationError.self) { try automationRequest(directory, operations: []).execute() }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path).hasSuffix("missing.png"))
    #expect(try Data(contentsOf: input) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".picglide-") })
}

@Test func agentConcurrentWritersCreateExactlyOneCompleteFile() async throws {
    let (directory, image) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("race.png"), frame = RenderedImage(image: image, bounds: .zero)
    let successes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                do { try ImageFiles.save(image: frame.image, format: .png, to: target, policy: .createNew); return true }
                catch { return false }
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    #expect(successes == 1)
    #expect(try ImageMetadata.read(target).pixelSize == CGSize(width: 120, height: 100))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".picglide-") })
}

@Test func agentUsesOrientedPixelsAndExportsJPEG() throws {
    let (directory, image) = try automationFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let input = directory.appendingPathComponent("rotated.jpg")
    try (data as Data).write(to: input)
    #expect(try ImageMetadata.read(input).pixelSize == CGSize(width: 100, height: 120))
    let request = try AutomationRequest(data: JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
        "input": input.path, "output": directory.appendingPathComponent("oriented.jpg").path,
        "operations": [["type": "crop", "x": 10, "y": 50, "width": 80, "height": 60]]]))
    let rendered = try request.execute()
    let oriented = try ImageCodec.decode(input, maxDimension: 120)
    let expected = try ImageRenderer.render(source: oriented, originalBounds: CGRect(x: 0, y: 0, width: 100, height: 120),
        operations: [.crop(CGRect(x: 10, y: 50, width: 80, height: 60))])
    #expect(try automationPixels(rendered.image) == automationPixels(expected.image))
    #expect(try ImageMetadata.read(request.output).pixelSize == CGSize(width: 80, height: 60))
}

@Test func fitReservesRoomForImageEdgesAndCropHandles() {
    for viewSize in [CGSize(width: 620, height: 288), CGSize(width: 1100, height: 608)] {
        var viewport = Viewport(viewSize: viewSize, imageBounds: CGRect(x: 100, y: 80, width: 1400, height: 1100))
        viewport.fit(inset: 12)
        #expect(viewport.imageRect.minX >= 11.99 && viewport.imageRect.minY >= 11.99)
        #expect(viewport.imageRect.maxX <= viewSize.width - 11.99 && viewport.imageRect.maxY <= viewSize.height - 11.99)
    }
}
