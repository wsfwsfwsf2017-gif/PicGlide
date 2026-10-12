#if DEBUG
import AppKit
import PicGlideCore
import Darwin

@MainActor
func runSmokeChecks(delegate: AppDelegate) async {
    guard let path = ProcessInfo.processInfo.environment["PICGLIDE_SMOKE_OUTPUT"] else { return }
    let output = URL(fileURLWithPath: path)
    var checks: [String] = []
    var measurements: [String: Any] = [:]
    func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<800 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "PicGlideSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "UI check timed out"])
    }
    func capture(_ name: String) throws {
        guard let view = delegate.window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    func findCanvas(_ view: NSView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        return view.subviews.compactMap(findCanvas).first
    }
    func key(_ code: UInt16, canvas: CanvasView, up: Bool = false) {
        let event = NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        if up { canvas.keyUp(with: event) } else { canvas.keyDown(with: event) }
    }
    func drag(_ first: CGPoint, _ last: CGPoint, canvas: CanvasView) {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, first), (.leftMouseDragged, last), (.leftMouseUp, last)] {
            let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type { case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event) }
        }
    }
    func respondToAlert(_ title: String) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                @MainActor func button(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == title { return button }
                    return view.subviews.compactMap(button).first
                }
                if let view = NSApp.modalWindow?.contentView, let button = button(in: view) {
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?
                            .write(to: output.appendingPathComponent("unsaved-dialog.png"))
                    }
                    button.performClick(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output.appendingPathComponent("ui-report.json"))
        try? FileManager.default.removeItem(at: output.appendingPathComponent("failure.txt"))
        let context = try ImageRenderer.context(width: 1800, height: 1200)
        let colors = [CGColor(red: 0.08, green: 0.2, blue: 0.34, alpha: 1),
                      CGColor(red: 0.24, green: 0.53, blue: 0.67, alpha: 1),
                      CGColor(red: 0.77, green: 0.84, blue: 0.82, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1800, y: 1200), options: [])
        context.setFillColor(CGColor(red: 1, green: 0.87, blue: 0.56, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1170, y: 680, width: 280, height: 280))
        context.setFillColor(CGColor(red: 0.08, green: 0.25, blue: 0.3, alpha: 1))
        context.move(to: .zero); context.addLine(to: CGPoint(x: 520, y: 720))
        context.addLine(to: CGPoint(x: 1000, y: 130)); context.addLine(to: CGPoint(x: 1400, y: 570))
        context.addLine(to: CGPoint(x: 1800, y: 0)); context.closePath(); context.fillPath()
        let image = context.makeImage()!
        let fixture = output.appendingPathComponent("01-landscape.png")
        try ImageFiles.save(image: image, format: .png, to: fixture)
        try ImageFiles.save(image: image, format: .webp, to: output.appendingPathComponent("02-landscape.webp"))
        let model = delegate.model
        let started = Date()
        model.requestOpen(fixture)
        try await wait { model.frame != nil && !model.isLoading }
        let firstImageTime = Date().timeIntervalSince(started)
        try await Task.sleep(for: .milliseconds(350))
        guard let canvas = findCanvas(delegate.window.contentView!) else {
            throw NSError(domain: "PicGlideSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Canvas not attached"])
        }
        delegate.window.appearance = NSAppearance(named: .darkAqua)
        model.revealControls(); try await Task.sleep(for: .milliseconds(200)); try capture("viewer-dark")
        delegate.window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(200)); try capture("viewer-light")
        checks.append("Light and dark native window rendered")
        let oldPan = canvas.viewport.pan
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        drag(center, CGPoint(x: center.x + 45, y: center.y + 30), canvas: canvas)
        guard canvas.viewport.pan != oldPan else { fatalError("Pan failed") }
        checks.append("Left-drag pan")
        let scale = canvas.viewport.scale
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
        canvas.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        guard canvas.viewport.scale > scale else { fatalError("Wheel zoom failed") }
        checks.append("Scroll-wheel zoom")
        let index = model.index
        key(124, canvas: canvas)
        try await wait { !model.isLoading && model.index == index + 1 }
        checks.append("Arrow-key next image")
        key(123, canvas: canvas)
        try await wait { !model.isLoading && model.currentURL == fixture }
        model.setZoom(actualSize: false)
        model.toggleEditing()
        try await wait { model.isEditing && !model.isPreparingEdit }
        try await Task.sleep(for: .milliseconds(100))
        model.chooseTool(.pencil); canvas.update()
        let a = canvas.viewport.viewPoint(from: CGPoint(x: 200, y: 220))
        let b = canvas.viewport.viewPoint(from: CGPoint(x: 600, y: 380))
        drag(a, b, canvas: canvas)
        try await wait { model.history.operations.count == 1 }
        checks.append("Pencil gesture")
        respondToAlert("取消")
        model.navigate(1)
        guard model.currentURL == fixture && model.isDirty else { fatalError("Cancel lost edits") }
        checks.append("Native unsaved-dialog cancel preserves edits")
        model.chooseTool(.rectangle); canvas.update()
        drag(canvas.viewport.viewPoint(from: CGPoint(x: 900, y: 320)),
             canvas.viewport.viewPoint(from: CGPoint(x: 1450, y: 850)), canvas: canvas)
        model.chooseTool(.mosaic); canvas.update()
        drag(canvas.viewport.viewPoint(from: CGPoint(x: 1000, y: 400)),
             canvas.viewport.viewPoint(from: CGPoint(x: 1280, y: 650)), canvas: canvas)
        try await Task.sleep(for: .milliseconds(300))
        checks.append("Rectangle and mosaic gestures")
        model.chooseTool(.crop); canvas.update()
        drag(canvas.viewport.viewPoint(from: CGPoint(x: 150, y: 100)),
             canvas.viewport.viewPoint(from: CGPoint(x: 1600, y: 1050)), canvas: canvas)
        key(36, canvas: canvas)
        try await wait { model.frame?.bounds.width == 1450 }
        model.undo(); try await wait { model.frame?.bounds.width == 1800 }
        model.redo(); try await wait { model.frame?.bounds.width == 1450 }
        checks.append("Crop, undo, redo")
        model.chooseTool(.pencil)
        try await Task.sleep(for: .milliseconds(150)); try capture("editor-light")
        delegate.window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(150)); try capture("editor-dark")
        delegate.window.setContentSize(NSSize(width: 620, height: 440))
        try await Task.sleep(for: .milliseconds(200)); try capture("editor-small")
        delegate.window.toggleFullScreen(nil)
        try await wait { delegate.window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .milliseconds(600)); try capture("editor-fullscreen")
        delegate.window.toggleFullScreen(nil)
        try await wait { !delegate.window.styleMask.contains(.fullScreen) }
        checks.append("Native fullscreen")
        model.save()
        try await wait { !model.isSaving && !model.isDirty }
        guard try ImageMetadata.read(fixture).pixelSize == CGSize(width: 1450, height: 950) else { fatalError("Save mismatch") }
        checks.append("UI overwrite save and pixel dimensions")
        model.commit(.rectangle(CGRect(x: 300, y: 300, width: 100, height: 100), ink: model.ink, width: 3))
        respondToAlert("放弃")
        model.navigate(1)
        try await wait { !model.isLoading && model.currentURL != fixture }
        checks.append("Native unsaved-dialog discard navigates")
        model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
        model.commit(.rectangle(CGRect(x: 300, y: 300, width: 100, height: 100), ink: model.ink, width: 3))
        respondToAlert("保存")
        model.navigate(-1)
        try await wait { !model.isLoading && !model.isSaving && model.currentURL == fixture }
        checks.append("Native unsaved-dialog save overwrites WebP then navigates")
        delegate.window.makeFirstResponder(canvas)
        model.revealControls()
        try await wait { !model.controlsVisible }
        let movement = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: delegate.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        canvas.mouseMoved(with: movement)
        guard model.controlsVisible, delegate.window.acceptsMouseMovedEvents else { fatalError("Toolbar reveal failed") }
        checks.append("Toolbar hides after idle and reappears on mouse movement")

        if ProcessInfo.processInfo.environment["PICGLIDE_PROFILE"] == "1" {
            let folder = output.appendingPathComponent("performance")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jpeg = try ImageCodec.encode(image, format: .jpeg)
            for index in 0..<1000 { try jpeg.write(to: folder.appendingPathComponent("photo\(index).jpg")) }
            let largeURL = folder.appendingPathComponent("zz-large-24mp.jpg")
            try autoreleasepool {
                let large = try ImageRenderer.context(width: 6000, height: 4000)
                large.interpolationQuality = .high
                large.draw(image, in: CGRect(x: 0, y: 0, width: 6000, height: 4000))
                try ImageFiles.save(image: large.makeImage()!, format: .jpeg, to: largeURL)
            }
            let largeStart = Date()
            model.requestOpen(largeURL)
            try await wait { !model.isLoading && model.frame != nil }
            measurements["preview24mpSeconds"] = Date().timeIntervalSince(largeStart)
            measurements["folderImageCount"] = model.files.count
            let fullStart = Date()
            model.setZoom(actualSize: true)
            try await wait { model.frame?.image.width == 6000 }
            measurements["fullResolution24mpSeconds"] = Date().timeIntervalSince(fullStart)
            measurements["fullResolutionResidentMiB"] = residentMiB()
            model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
            let editStart = Date()
            do {
                let previousFrame = model.frame!.image
                model.commit(.rectangle(CGRect(x: 1200, y: 800, width: 2000, height: 1200), ink: model.ink, width: 12))
                try await wait { model.frame?.image !== previousFrame }
            }
            measurements["edit24mpSeconds"] = Date().timeIntervalSince(editStart)
            measurements["editingResidentMiB"] = residentMiB()
            let saveStart = Date()
            model.save(); try await wait { !model.isSaving && !model.isDirty }
            measurements["save24mpSeconds"] = Date().timeIntervalSince(saveStart)
            model.setZoom(actualSize: false)
            let navigationStart = Date()
            var samples: [String: Double] = [:]
            for step in 1...100 {
                let index = model.index
                model.navigate(-1)
                try await wait { !model.isLoading && model.frame != nil && model.index == index - 1 }
                try await Task.sleep(for: .milliseconds(15))
                if [20, 50, 100].contains(step) { samples["after\(step)ImagesMiB"] = residentMiB() }
            }
            measurements["navigation100ImagesSeconds"] = Date().timeIntervalSince(navigationStart)
            measurements["navigationResidentMiB"] = samples
            checks.append("24MP preview, full resolution, edit, save; 100 navigations in 1001-image folder")
        }
        let report: [String: Any] = ["checks": checks, "firstImageSeconds": firstImageTime,
            "architecture": "arm64", "imageSize": "1800x1200", "measurements": measurements]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("ui-report.json"))
        print("PICGLIDE_UI_SMOKE_PASS \(checks.count) checks")
    } catch {
        try? error.localizedDescription.write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
        print("PICGLIDE_UI_SMOKE_FAIL \(error)")
    }
    delegate.model.history.markSaved()
    NSApp.terminate(nil)
}
#endif
