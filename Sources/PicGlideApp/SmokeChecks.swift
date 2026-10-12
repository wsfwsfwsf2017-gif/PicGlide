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
    var passed = false
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
    func doubleClickHeader() {
        let event = NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: delegate.window.frame.width / 2, y: delegate.window.frame.height - 16),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: delegate.window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
        delegate.window.sendEvent(event)
    }
    func checkHeaderFill(_ label: String) async throws {
        let original = delegate.window.frame
        let available = delegate.window.screen!.visibleFrame
        doubleClickHeader()
        try await Task.sleep(for: .milliseconds(400))
        guard delegate.window.frame.equalTo(available) else {
            throw NSError(domain: "PicGlideSmoke", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Header double-click did not fill desktop: \(delegate.window.frame)"])
        }
        doubleClickHeader()
        try await Task.sleep(for: .milliseconds(400))
        guard delegate.window.frame.equalTo(original) else {
            throw NSError(domain: "PicGlideSmoke", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Header double-click did not restore window"])
        }
        checks.append(label)
    }
    func cursorRegions(in view: NSView) -> [CursorRegionView] {
        (view as? CursorRegionView).map { [$0] } ?? view.subviews.flatMap(cursorRegions)
    }
    func nativeControls(in view: NSView) -> [NSControl] {
        (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(nativeControls)
    }
    func navigationButton() -> CursorRegionView? {
        CursorRegionView.regions(in: delegate.window.contentView!).first {
            abs($0.cursorRect.width - 44) < 0.5 && abs($0.cursorRect.height - 56) < 0.5
        }
    }
    func showNavigation(_ direction: Int, canvas: CanvasView) async throws -> CursorRegionView {
        try await hover(canvas, point: NSPoint(x: direction < 0 ? 20 : canvas.bounds.maxX - 20, y: canvas.bounds.midY))
        try await wait { navigationButton() != nil }
        let button = navigationButton()!
        try await hover(button)
        let area = canvas.convert(button.cursorRect, from: button)
        guard canvas.canvasCursorRects.allSatisfy({ $0.intersection(area).isEmpty }),
              NSCursor.current === button.cursor else { fatalError("Navigation cursor overlaps canvas or fails to match button") }
        return button
    }
    func clickNavigation() {
        let button = navigationButton()!
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        mouse(.leftMouseDown, at: point); mouse(.leftMouseUp, at: point)
    }
    func saveButtonRect() -> NSRect {
        let region = cursorRegions(in: delegate.window.contentView!).first {
            abs($0.cursorRect.width - 52) < 0.5 && abs($0.cursorRect.height - 32) < 0.5
        }!
        return region.convert(region.cursorRect, to: nil)
    }
    func checkToolbarLayout(_ label: String) {
        let toolbar = delegate.model.toolbarCursorRegion!
        let rect = toolbar.convert(toolbar.cursorRect, to: delegate.window.contentView!)
        guard rect.height <= 96, rect.minX >= 16,
              rect.maxX <= delegate.window.contentView!.bounds.width - 16 else { fatalError("Toolbar does not fit minimum window") }
        measurements[label] = ["width": rect.width, "height": rect.height]
        checks.append(label)
    }
    func mouse(_ type: CGEventType, at point: NSPoint) {
        let screenPoint = delegate.window.convertPoint(toScreen: point)
        let location = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }
    func hover(_ view: NSView, point: NSPoint? = nil) async throws {
        for _ in 0..<3 {
            delegate.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(50))
            let target = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            mouse(.mouseMoved, at: target)
            try await Task.sleep(for: .milliseconds(100))
            let actual = delegate.window.mouseLocationOutsideOfEventStream
            // Retry only when external mouse movement or focus changes interrupted the input.
            if NSApp.isActive && delegate.window.isKeyWindow && hypot(actual.x - target.x, actual.y - target.y) < 5 { return }
        }
        throw NSError(domain: "PicGlideSmoke", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Native pointer check interrupted by mouse movement or focus changes"])
    }
    func checkToolbarCursor(_ canvas: CanvasView, label: String) async throws {
        guard let toolbar = delegate.model.toolbarCursorRegion else { fatalError("Toolbar cursor region missing") }
        let toolbarArea = canvas.convert(toolbar.cursorRect, from: toolbar)
        guard canvas.canvasCursorRects.allSatisfy({ $0.intersection(toolbarArea).isEmpty }) else {
            fatalError("Canvas cursor overlaps toolbar")
        }
        let regions = cursorRegions(in: delegate.window.contentView!)
        guard let button = regions.first(where: { $0.cursor === NSCursor.pointingHand && !$0.cursorRect.isEmpty }) else {
            fatalError("No clickable cursor region")
        }
        try await hover(button)
        guard NSCursor.current === NSCursor.pointingHand else {
            throw NSError(domain: "PicGlideSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Button hover is not pointing hand: arrow=\(NSCursor.current === NSCursor.arrow), active=\(NSApp.isActive), key=\(delegate.window.isKeyWindow), frame=\(button.convert(button.bounds, to: nil)), mouse=\(delegate.window.mouseLocationOutsideOfEventStream), toolbar=\(toolbar.convert(toolbar.cursorRect, to: nil)), selected=\(CursorRegionView.cursor(at: delegate.window.mouseLocationOutsideOfEventStream, in: delegate.window.contentView!) === NSCursor.pointingHand)"])
        }
        if let disabled = regions.first(where: { $0 !== toolbar && $0.cursor === NSCursor.arrow && !$0.cursorRect.isEmpty }) {
            try await hover(disabled)
            guard NSCursor.current === NSCursor.arrow else { fatalError("Disabled button hover is not arrow") }
        }
        try await hover(toolbar, point: NSPoint(x: 4, y: toolbar.bounds.midY))
        guard NSCursor.current === NSCursor.arrow else { fatalError("Toolbar background hover is not arrow") }
        try await hover(canvas)
        guard NSCursor.current === canvas.canvasCursor else { fatalError("Canvas cursor did not restore") }
        checks.append(label)
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
        try capture("welcome")
        try await checkHeaderFill("Empty window header fills desktop and restores frame")
        let originalFrame = delegate.window.frame
        for screen in NSScreen.screens {
            delegate.window.setFrame(screen.visibleFrame.insetBy(dx: 100, dy: 100), display: true)
            try await checkHeaderFill("Header fill and restore on \(screen.localizedName)")
        }
        delegate.window.setFrame(originalFrame, display: true)
        let viewerWindow = delegate.window!
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = delegate.window.standardWindowButton(type)!
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard !viewerWindow.isHeaderLocation(center) else { fatalError("Titlebar includes window button") }
        }
        guard !viewerWindow.isHeaderLocation(NSPoint(x: originalFrame.width / 2, y: 100)) else {
            fatalError("Canvas included in header")
        }
        checks.append("Header excludes traffic-light buttons and canvas")
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
        let mousePosition = CGEvent(source: nil)!.location
        defer { CGWarpMouseCursorPosition(mousePosition) }
        let navigationFolder = output.appendingPathComponent("navigation")
        let singleFolder = navigationFolder.appendingPathComponent("single")
        try FileManager.default.createDirectory(at: singleFolder, withIntermediateDirectories: true)
        for name in ["01.png", "02.png", "03.png"] {
            try ImageFiles.save(image: image, format: .png, to: navigationFolder.appendingPathComponent(name))
        }
        let singleImage = singleFolder.appendingPathComponent("only.png")
        try ImageFiles.save(image: image, format: .png, to: singleImage)
        model.requestOpen(navigationFolder.appendingPathComponent("01.png"))
        try await wait { !model.isLoading && model.frame != nil && model.files.count == 3 }
        try await hover(canvas)
        try await Task.sleep(for: .milliseconds(150))
        guard navigationButton() == nil else { fatalError("Navigation visible in canvas center") }
        let left = try await showNavigation(-1, canvas: canvas)
        guard left.cursor === NSCursor.arrow else { fatalError("First image previous button is enabled") }
        clickNavigation(); try await Task.sleep(for: .milliseconds(150))
        guard model.index == 0 else { fatalError("Previous button wrapped before first image") }
        checks.append("Edge navigation hides in center and disables previous at first image")
        let right = try await showNavigation(1, canvas: canvas)
        guard right.cursor === NSCursor.pointingHand else { fatalError("Next button is not clickable") }
        try capture("viewer-edge-navigation")
        let beforeNavigationPan = canvas.viewport.pan
        clickNavigation()
        try await wait { !model.isLoading && model.frame != nil && model.index == 1 && navigationButton() != nil }
        guard canvas.viewport.pan == beforeNavigationPan else { fatalError("Navigation click panned image") }
        clickNavigation()
        try await wait { !model.isLoading && model.frame != nil && model.index == 2 && navigationButton() != nil }
        try await hover(navigationButton()!)
        guard navigationButton()!.cursor === NSCursor.arrow else { fatalError("Last image next button is enabled") }
        clickNavigation(); try await Task.sleep(for: .milliseconds(150))
        guard model.index == 2 else { fatalError("Next button wrapped after last image") }
        checks.append("Native next button supports repeated clicks without moving pointer and stops at last image")
        _ = try await showNavigation(-1, canvas: canvas)
        clickNavigation()
        try await wait { !model.isLoading && model.frame != nil && model.index == 1 }
        checks.append("Native previous button navigates backward")
        try await hover(canvas, point: NSPoint(x: 20, y: 60))
        let edgePoint = canvas.convert(NSPoint(x: 20, y: 60), to: nil)
        let beforeEdgeDrag = canvas.viewport.pan
        mouse(.leftMouseDown, at: edgePoint)
        try await Task.sleep(for: .milliseconds(80))
        mouse(.leftMouseDragged, at: NSPoint(x: edgePoint.x + 18, y: edgePoint.y + 12))
        try await Task.sleep(for: .milliseconds(80))
        mouse(.leftMouseUp, at: NSPoint(x: edgePoint.x + 18, y: edgePoint.y + 12))
        try await Task.sleep(for: .milliseconds(100))
        guard canvas.viewport.pan != beforeEdgeDrag else { fatalError("Edge hover blocked canvas drag outside navigation button") }
        checks.append("Canvas remains draggable in edge hover area outside navigation button")
        model.requestOpen(singleImage)
        try await wait { !model.isLoading && model.frame != nil && model.files.count == 1 }
        for direction in [-1, 1] {
            try await hover(canvas, point: NSPoint(x: direction < 0 ? 20 : canvas.bounds.maxX - 20, y: canvas.bounds.midY))
            try await Task.sleep(for: .milliseconds(150))
            guard model.navigationHover == 0 && navigationButton() == nil else { fatalError("Single-image folder shows navigation") }
        }
        checks.append("Single-image folder hides both edge navigation buttons")
        model.requestOpen(fixture)
        try await wait { !model.isLoading && model.frame != nil && model.currentURL == fixture }
        try await hover(canvas)
        try await checkHeaderFill("Image window header fills desktop and restores frame")
        try await checkToolbarCursor(canvas, label: "Viewer native mouse: clickable hand, disabled/background arrow, canvas hand")
        let beforeWindowDrag = delegate.window.frame
        let headerPoint = NSPoint(x: beforeWindowDrag.width / 2, y: beforeWindowDrag.height - 16)
        let beforeHeaderPan = canvas.viewport.pan
        mouse(.mouseMoved, at: headerPoint)
        mouse(.leftMouseDown, at: headerPoint)
        try await Task.sleep(for: .milliseconds(100))
        mouse(.leftMouseDragged, at: NSPoint(x: headerPoint.x + 30, y: headerPoint.y - 12))
        try await Task.sleep(for: .milliseconds(100))
        mouse(.leftMouseUp, at: headerPoint)
        try await Task.sleep(for: .milliseconds(100))
        guard delegate.window.frame.origin != beforeWindowDrag.origin && canvas.viewport.pan == beforeHeaderPan else {
            throw NSError(domain: "PicGlideSmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Native titlebar drag did not move only the window"])
        }
        delegate.window.setFrame(beforeWindowDrag, display: true)
        checks.append("Native header drag moves window without panning image")
        let canvasPoint = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        let beforeNativePan = canvas.viewport.pan
        mouse(.leftMouseDown, at: canvasPoint)
        try await Task.sleep(for: .milliseconds(100))
        guard NSCursor.current === NSCursor.closedHand else { fatalError("Native pan did not close hand cursor") }
        mouse(.leftMouseDragged, at: NSPoint(x: canvasPoint.x + 15, y: canvasPoint.y + 12))
        try await Task.sleep(for: .milliseconds(100))
        mouse(.leftMouseUp, at: NSPoint(x: canvasPoint.x + 15, y: canvasPoint.y + 12))
        try await Task.sleep(for: .milliseconds(100))
        guard canvas.viewport.pan != beforeNativePan && NSCursor.current === NSCursor.openHand else {
            fatalError("Native pan did not move image and restore open hand")
        }
        checks.append("Native canvas drag uses closed hand and restores open hand")
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
        canvas.update()
        let editButton = cursorRegions(in: delegate.window.contentView!)
            .filter { $0.cursor === NSCursor.pointingHand }
            .max { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }!
        let panBeforeClick = canvas.viewport.pan
        let buttonCenter = editButton.convert(NSPoint(x: editButton.bounds.midX, y: editButton.bounds.midY), to: nil)
        mouse(.leftMouseDown, at: buttonCenter); mouse(.leftMouseUp, at: buttonCenter)
        try await wait { model.isEditing && !model.isPreparingEdit }
        guard canvas.viewport.pan == panBeforeClick else { fatalError("Toolbar click panned image") }
        checks.append("Native toolbar button click enters editor without panning image")
        try await Task.sleep(for: .milliseconds(100))
        model.chooseTool(.pencil); canvas.update()
        try await Task.sleep(for: .milliseconds(150))
        try await hover(canvas, point: NSPoint(x: 20, y: canvas.bounds.midY))
        guard navigationButton() == nil && model.navigationHover == 0,
              NSCursor.current === NSCursor.crosshair else { fatalError("Editing shows edge navigation or hides drawing cursor") }
        checks.append("Editor hides edge navigation and preserves drawing cursor")
        let cleanSaveRect = saveButtonRect()
        guard !model.canSave else { fatalError("Save enabled on clean image") }
        try await checkHeaderFill("Editing window header fills desktop and restores frame")
        try await checkToolbarCursor(canvas, label: "Editor native mouse restores crosshair outside controls")
        key(49, canvas: canvas)
        try await hover(canvas)
        guard NSCursor.current === NSCursor.openHand else { fatalError("Space did not switch cursor to hand") }
        key(49, canvas: canvas, up: true)
        try await hover(canvas)
        guard NSCursor.current === NSCursor.crosshair else { fatalError("Space release did not restore crosshair") }
        checks.append("Space temporarily changes editor cursor to hand")
        let controls = nativeControls(in: delegate.window.contentView!)
        measurements["editorNativeControls"] = controls.map { String(describing: type(of: $0)) }
        for control in controls where control is NSSlider || control is NSColorWell {
            try await hover(control)
            guard NSCursor.current === NSCursor.arrow else { fatalError("Native editor control cursor is not arrow") }
        }
        let sliders = cursorRegions(in: delegate.window.contentView!).filter {
            $0.cursor === NSCursor.arrow && $0.cursorRect.width > 80 && $0.cursorRect.height < 30
        }
        guard sliders.count == 2 else { fatalError("Editor slider cursor regions missing") }
        for slider in sliders {
            try await hover(slider)
            guard NSCursor.current === NSCursor.arrow else { fatalError("Slider hover did not use arrow") }
        }
        let widthSlider = sliders.first { abs($0.cursorRect.width - 94) < 1 }!
        let sliderPoint = widthSlider.convert(NSPoint(x: widthSlider.bounds.width * 0.75, y: widthSlider.bounds.midY), to: nil)
        let originalWidth = model.lineWidth
        mouse(.leftMouseDown, at: sliderPoint); mouse(.leftMouseUp, at: sliderPoint)
        try await wait { model.lineWidth != originalWidth }
        model.lineWidth = originalWidth
        checks.append("Native slider hover uses arrow and click changes brush width")
        if let colorWell = controls.first(where: { $0 is NSColorWell }) as? NSColorWell {
            colorWell.performClick(nil)
            try await wait { NSColorPanel.shared.isVisible }
            NSColorPanel.shared.close()
            try await hover(canvas)
            guard NSCursor.current === NSCursor.crosshair else { fatalError("Color panel close did not restore canvas cursor") }
            checks.append("Native color picker and panel close preserve cursor behavior")
        }
        let a = canvas.viewport.viewPoint(from: CGPoint(x: 200, y: 220))
        let b = canvas.viewport.viewPoint(from: CGPoint(x: 600, y: 380))
        drag(a, b, canvas: canvas)
        try await wait { model.history.operations.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        guard model.canSave && saveButtonRect().equalTo(cleanSaveRect) else { fatalError("Save position changed with dirty state") }
        checks.append("Save stays visible and stationary across clean and dirty states")
        checks.append("Pencil gesture")
        respondToAlert("取消")
        model.navigate(1)
        guard model.currentURL == fixture && model.isDirty else { fatalError("Cancel lost edits") }
        checks.append("Native unsaved-dialog cancel preserves edits")
        let editedOperations = model.history.operations
        let fileBeforeExit = try Data(contentsOf: fixture)
        model.toggleEditing()
        try await Task.sleep(for: .milliseconds(150))
        guard !model.isEditing, model.isDirty, model.canSave,
              model.history.operations == editedOperations,
              try Data(contentsOf: fixture) == fileBeforeExit else { fatalError("Return to browse lost or saved edits") }
        try capture("viewer-unsaved")
        let dialog = output.appendingPathComponent("unsaved-dialog.png")
        try FileManager.default.removeItem(at: dialog)
        _ = try await showNavigation(1, canvas: canvas)
        respondToAlert("取消")
        clickNavigation()
        try await wait { FileManager.default.fileExists(atPath: dialog.path) && NSApp.modalWindow == nil }
        guard model.currentURL == fixture, model.isDirty,
              model.history.operations == editedOperations,
              try Data(contentsOf: fixture) == fileBeforeExit else { fatalError("Edge navigation bypassed unsaved-edit protection") }
        checks.append("Edge button triggers unsaved prompt and cancel preserves edits and file")
        model.toggleEditing(); model.chooseTool(.pencil); canvas.update()
        checks.append("Return to browse preserves unsaved edits without writing file")
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
        let pending = model.pendingCrop
        let beforeBlockedSave = try Data(contentsOf: fixture)
        guard pending != nil, !model.canSave, !model.canSaveCopy else { fatalError("Pending crop did not disable save") }
        for (action, asCopy) in [(#selector(AppDelegate.saveImage), false), (#selector(AppDelegate.saveCopy), true)] {
            let entry = NSMenuItem(title: "保存", action: action, keyEquivalent: "s")
            guard !delegate.validateMenuItem(entry) else { fatalError("Menu save enabled with pending crop") }
            respondToAlert("好")
            var refused = false
            model.save(asCopy: asCopy) { refused = !$0 }
            guard refused, model.pendingCrop == pending,
                  try Data(contentsOf: fixture) == beforeBlockedSave else { fatalError("Pending crop save modified file or selection") }
        }
        checks.append("Pending crop blocks save and Save As in controls, menu and shared save entry")
        key(53, canvas: canvas)
        guard model.pendingCrop == nil, model.canSave else { fatalError("Cancel crop did not re-enable save") }
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
        for tool in EditTool.allCases {
            model.chooseTool(tool); canvas.update()
            try await Task.sleep(for: .milliseconds(100))
            checkToolbarLayout("Minimum-window \(tool.rawValue) toolbar fits within 96pt")
        }
        model.chooseTool(.pencil); canvas.update()
        delegate.window.toggleFullScreen(nil)
        try await wait { delegate.window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .milliseconds(600)); try capture("editor-fullscreen")
        let fullScreenFrame = delegate.window.frame
        doubleClickHeader()
        try await Task.sleep(for: .milliseconds(200))
        guard delegate.window.styleMask.contains(.fullScreen) && delegate.window.frame.equalTo(fullScreenFrame) else {
            fatalError("Header double-click changed fullscreen")
        }
        checks.append("Header double-click leaves native fullscreen unchanged")
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
        try await Task.sleep(for: .milliseconds(250))
        try await checkToolbarCursor(canvas, label: "Cursor regions restore after toolbar hide and reveal")

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
        passed = true
    } catch {
        try? error.localizedDescription.write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
        print("PICGLIDE_UI_SMOKE_FAIL \(error)")
    }
    if !passed { exit(EXIT_FAILURE) }
    delegate.model.history.markSaved()
    NSApp.terminate(nil)
}
#endif
