import AppKit

let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")
let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL))!
precondition(source.pixelsWide == 1024 && source.pixelsHigh == 1024 && source.hasAlpha,
             "AppIcon.png must be a 1024 × 1024 PNG with alpha")
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        // Opaque tile and clean alpha prevent macOS from adding a second icon background.
        let tile = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            .insetBy(dx: CGFloat(pixels) * 100 / 1024, dy: CGFloat(pixels) * 100 / 1024)
        let radius = CGFloat(pixels) * 185 / 1024
        context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.setFillColor(NSColor(srgbRed: 0.965, green: 0.459, blue: 0.314, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.draw(source.cgImage!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let representation = NSBitmapImageRep(cgImage: context.makeImage()!)
        let name = "icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"
        let output = destination.appendingPathComponent(name)
        try representation.representation(using: .png, properties: [:])!.write(to: output)
        let saved = NSBitmapImageRep(data: try Data(contentsOf: output))!
        precondition(saved.pixelsWide == pixels && saved.pixelsHigh == pixels && saved.hasAlpha)
        precondition(saved.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        precondition(saved.colorAt(x: pixels / 2, y: pixels / 2)!.alphaComponent == 1)
    }
}
let generated = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".png") }
assert(generated.count == 10)
