#if DEBUG
import AppKit
import SwiftUI
import PicGlideCore
import Darwin

@MainActor
func runLayoutChecks(delegate: AppDelegate, output: URL) async {
    let model = delegate.model, window = delegate.window!
    var records: [[String: Any]] = []
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "LayoutChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待界面超时"])
    }
    func capture(_ name: String) throws {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try capture("welcome")
        let fixture = output.deletingLastPathComponent().appendingPathComponent("图片浏览与标注验证-长文件名布局测试.png")
        if !FileManager.default.fileExists(atPath: fixture.path) {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(white: 0.98, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1400, height: 1100).fill()
            for index in 0..<12 {
                let y = CGFloat(index * 85 + 25)
                let value = "\(index + 1). 图片浏览与标注 / Image editing — 完整显示边缘内容"
                value.draw(at: NSPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.darkGray])
            }
            NSColor.systemRed.setStroke(); let edge = NSBezierPath(rect: NSRect(x: 4, y: 4, width: 1392, height: 1092)); edge.lineWidth = 8; edge.stroke()
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: fixture)
        }
        model.requestOpen(fixture)
        try await wait { model.frame != nil && !model.isLoading }
        let screen = window.screen!
        let sizes = [NSSize(width: 620, height: 440), NSSize(width: 1100, height: 760), screen.visibleFrame.size]
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (sizeIndex, size) in sizes.enumerated() {
                if window.isZoomed { window.zoom(nil) }
                window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height), display: true)
                if model.isEditing { model.toggleEditing() }
                model.setZoom(actualSize: false)
                try await Task.sleep(for: .milliseconds(180))
                let prefix = "\(dark ? "dark" : "light")-\(sizeIndex)"
                try capture(prefix + "-browse")
                model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
                for tool in EditTool.allCases {
                    let canvasBefore = model.canvas!
                    let anchorBefore = canvasBefore.convert(canvasBefore.viewport.viewPoint(from: canvasBefore.viewport.imageBounds.origin), to: nil)
                    let scaleBefore = canvasBefore.viewport.scale
                    model.chooseTool(tool)
                    try await Task.sleep(for: .milliseconds(100))
                    if ProcessInfo.processInfo.environment["PICGLIDE_LAYOUT_ASSERT"] == "1" {
                        let anchorAfter = canvasBefore.convert(canvasBefore.viewport.viewPoint(from: canvasBefore.viewport.imageBounds.origin), to: nil)
                        precondition(hypot(anchorBefore.x - anchorAfter.x, anchorBefore.y - anchorAfter.y) < 0.1 &&
                            abs(scaleBefore - canvasBefore.viewport.scale) < 0.0001, "Tool change moves the image")
                    }
                    model.setZoom(actualSize: false)
                    try await Task.sleep(for: .milliseconds(100))
                    let canvas = model.canvas!, imageRect = canvas.viewport.imageRect
                    let toolbar = model.toolbarCursorRegion.map { canvas.convert($0.cursorRect, from: $0) } ?? .zero
                    let fits = canvas.bounds.insetBy(dx: -0.1, dy: -0.1).contains(imageRect)
                    let overlaps = imageRect.intersects(toolbar)
                    records.append(["theme": dark ? "dark" : "light", "window": [size.width, size.height],
                        "tool": tool.rawValue, "imageFitsCanvas": fits, "imageOverlapsToolbar": overlaps])
                    if ProcessInfo.processInfo.environment["PICGLIDE_LAYOUT_ASSERT"] == "1" {
                        precondition(fits && !overlaps, "Fit image is clipped or overlaps toolbar")
                    }
                    if sizeIndex == 0 || tool == .mosaic { try capture(prefix + "-" + tool.rawValue) }
                }
            }
        }
        if ProcessInfo.processInfo.environment["PICGLIDE_LAYOUT_ASSERT"] == "1" {
            window.setContentSize(NSSize(width: 620, height: 440))
            for (name, width, height, alpha, gray) in [
                ("portrait", 800, 1600, 1.0, 0.25), ("long", 320, 2600, 1.0, 0.8),
                ("transparent", 1200, 900, 0.5, 0.3), ("white", 900, 700, 1.0, 1.0), ("black", 900, 700, 1.0, 0.0)
            ] {
                let context = try ImageRenderer.context(width: width, height: height)
                context.setFillColor(gray: gray, alpha: alpha)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let url = output.appendingPathComponent(name + "-fixture.png")
                try ImageFiles.save(image: context.makeImage()!, format: .png, to: url)
                model.requestOpen(url, fillWindow: false)
                try await wait { model.frame != nil && !model.isLoading }
                model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
                model.chooseTool(.mosaic)
                try await Task.sleep(for: .milliseconds(100))
                model.setZoom(actualSize: false)
                try await Task.sleep(for: .milliseconds(100))
                let canvas = model.canvas!, rect = canvas.viewport.imageRect
                precondition(canvas.bounds.contains(rect), "Image shape clips in editor")
                try capture("shape-" + name)
                records.append(["scenario": name, "imageFitsCanvas": true])
            }
            window.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
            window.contentView = NSHostingView(rootView: ViewerView(model: model))
            try await Task.sleep(for: .milliseconds(200))
            model.setZoom(actualSize: false)
            try await Task.sleep(for: .milliseconds(100))
            try capture("accessibility-high-contrast")
            records.append(["scenario": "app-scoped high-contrast appearance", "globalSettingsChanged": false])
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("layout-report.json"))
        print("PICGLIDE_LAYOUT_PASS \(records.count) observations")
        model.history.markSaved(); NSApp.terminate(nil)
    } catch {
        print("PICGLIDE_LAYOUT_FAIL \(error)"); exit(EXIT_FAILURE)
    }
}
#endif
