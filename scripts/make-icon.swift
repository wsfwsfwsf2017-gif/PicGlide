import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.23, blue: 0.31, alpha: 1),
                   ending: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.18, alpha: 1))!
            .draw(in: background, angle: 90)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 35, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        let card = NSBezierPath(roundedRect: NSRect(x: 220, y: 250, width: 584, height: 530), xRadius: 65, yRadius: 65)
        NSColor(srgbRed: 0.8, green: 0.88, blue: 0.92, alpha: 1).setFill(); card.fill()
        context.restoreGState()
        let inside = NSBezierPath(roundedRect: NSRect(x: 245, y: 275, width: 534, height: 480), xRadius: 44, yRadius: 44)
        NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.46, blue: 0.69, alpha: 1),
                   ending: NSColor(srgbRed: 0.41, green: 0.82, blue: 0.91, alpha: 1))!
            .draw(in: inside, angle: 90)
        context.saveGState(); inside.addClip()
        NSColor(srgbRed: 0.98, green: 0.93, blue: 0.73, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 587, y: 575, width: 107, height: 107)).fill()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 230, y: 275)); mountain.line(to: NSPoint(x: 400, y: 573))
        mountain.line(to: NSPoint(x: 588, y: 336)); mountain.line(to: NSPoint(x: 696, y: 473))
        mountain.line(to: NSPoint(x: 800, y: 275)); mountain.close()
        NSColor(srgbRed: 0.12, green: 0.32, blue: 0.44, alpha: 1).setFill(); mountain.fill()
        context.restoreGState()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"
        try representation.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
let generated = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".png") }
assert(generated.count == 10)
