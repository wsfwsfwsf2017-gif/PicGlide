#if DEBUG
import AppKit
import SwiftUI
import PicGlideCore
import Darwin

@MainActor
func runDrawingChecks(delegate: AppDelegate, output: URL) async {
    let model = delegate.model, window = delegate.window!
    var checks: [String] = []
    var responses = 0
    func wait(timeout: Int = 20, _ condition: () -> Bool) async throws {
        for _ in 0..<(timeout * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "DrawingChecks", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "等待超时，上一项：\(checks.last ?? "开始")"])
    }
    func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
    func control<T: NSView>(_ id: String, in panel: NSWindow, as type: T.Type) -> T {
        children(panel.contentView!).first { $0.identifier?.rawValue == id } as! T
    }
    func button(_ title: String, in panel: NSWindow) -> NSButton {
        children(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    func modal(_ action: @escaping @MainActor (NSWindow) -> Void) {
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            let ready = MainActor.assumeIsolated {
                guard let panel = NSApp.modalWindow ?? window.attachedSheet, panel.isVisible else {
                    precondition(Date().timeIntervalSince(started) < 15, "Expected visible modal window")
                    return false
                }
                return true
            }
            guard ready else { return }
            timer.invalidate()
            MainActor.assumeIsolated { action((NSApp.modalWindow ?? window.attachedSheet)!) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }
    func respond(_ title: String) { modal { button(title, in: $0).performClick(nil); responses += 1 } }
    func capture(_ name: String, in panel: NSWindow? = nil) throws {
        let view = (panel ?? window).contentView!
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let captured: NSBitmapImageRep
        if let panel {
            let context = try ImageRenderer.context(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            }
            let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            context.fill(rect); context.draw(bitmap.cgImage!, in: rect)
            captured = NSBitmapImageRep(cgImage: context.makeImage()!)
        } else { captured = bitmap }
        try captured.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    func editField(_ field: NSTextField, value: String) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func savePanel(to target: URL, format: ImageFormat = .png, cancel: Bool = false) {
        // System save panels live in an XPC service; exercise their actual controls with the external UI driver.
        let request: [String: Any] = ["target": target.path, "format": format.title, "cancel": cancel]
        try! JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("save-request.json"), options: .atomic)
        print("PICGLIDE_DRAWING_SAVE_REQUEST \(cancel ? "cancel" : format.title)"); fflush(stdout)
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output.appendingPathComponent("failure.txt"))
        try? FileManager.default.removeItem(at: output.appendingPathComponent("save-request.json"))
        let detachedRegion = CursorRegionView(model: nil)
        precondition(detachedRegion.cursorRect == .zero)
        detachedRegion.resetCursorRects()
        precondition(CanvasView(model: ViewerModel()).canvasCursorRects.isEmpty)
        checks.append("Detached and zero-size views do not register invalid cursor rectangles")
        let files = output.appendingPathComponent("files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try capture("welcome")
        modal { panel in
            let width = control("drawing.canvas.width", in: panel, as: NSTextField.self)
            let height = control("drawing.canvas.height", in: panel, as: NSTextField.self)
            precondition(width.stringValue == "1920" && height.stringValue == "1080")
            try! capture("new-canvas-default", in: panel)
            button("取消", in: panel).performClick(nil)
        }
        model.newCanvasPanel()
        precondition(model.frame == nil && model.currentURL == nil)
        checks.append("Cancel new canvas preserves empty viewer")

        modal { panel in
            let preset = control("drawing.canvas.preset", in: panel, as: NSSegmentedControl.self)
            preset.selectedSegment = 1; preset.sendAction(preset.action!, to: preset.target)
            precondition(control("drawing.canvas.width", in: panel, as: NSTextField.self).stringValue == "2560")
            button("创建", in: panel).performClick(nil)
        }
        model.newCanvasPanel()
        try await wait { !model.isCreatingCanvas && model.frame != nil }
        precondition(model.originalBounds?.size == CGSize(width: 2560, height: 1440) && model.metadata == nil &&
            model.currentURL == nil && model.isUntitled && model.isDirty && model.canSave && !model.canRestore &&
            model.isEditing && model.tool == .pencil && model.lineWidth == 6 && model.opacity == 1)
        try await Task.sleep(for: .milliseconds(150)); try capture("new-canvas")
        checks.append("Preset creates in-memory white canvas, default pencil, first-save and dirty state")

        let firstImageID = model.imageID, firstBounds = model.originalBounds
        // Preview resolution may increase during a dialog; compare document state and pixels, not CGImage identity.
        func unchangedCanvas() -> Bool {
            guard model.imageID == firstImageID, model.originalBounds == firstBounds,
                  model.frame?.bounds == firstBounds, model.currentURL == nil, model.history.operations.isEmpty,
                  let image = model.frame?.image, let context = try? ImageRenderer.context(width: 8, height: 8) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<256).allSatisfy { bytes[$0] == 255 }
        }
        modal { panel in
            let field = control("drawing.canvas.width", in: panel, as: NSTextField.self)
            editField(field, value: "0")
            precondition(!button("创建", in: panel).isEnabled)
            editField(field, value: "240")
            editField(control("drawing.canvas.height", in: panel, as: NSTextField.self), value: "160")
            precondition(button("创建", in: panel).isEnabled)
            try! capture("new-canvas-custom", in: panel)
            button("取消", in: panel).performClick(nil)
        }
        model.newCanvasPanel()
        precondition(unchangedCanvas() && model.isUntitled)
        respond("取消"); precondition(!delegate.windowShouldClose(window))
        respond("取消"); model.createCanvas(try CanvasSize(width: 1920, height: 1080))
        precondition(unchangedCanvas() && !model.isCreatingCanvas)
        let expectedResponse = responses + 1
        respond("取消")
        precondition(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        try await wait { responses == expectedResponse && NSApp.modalWindow == nil }
        precondition(unchangedCanvas() && NSApp.modalWindow == nil)
        checks.append("Custom validation and cancel preserve canvas; close, new and quit protect even a blank unsaved canvas")

        model.color = .white; model.chooseTool(.fill); model.fill(at: .zero)
        try await wait { !model.isFilling }
        precondition(model.history.operations.isEmpty && !model.canRestore)
        let ink = Ink(red: 0.15, green: 0.45, blue: 0.9)
        model.commit(.rectangle(CGRect(x: 100, y: 100, width: 500, height: 400), ink: ink, width: 6))
        try await wait { model.frameRevision == model.editRevision }
        model.color = Color(red: ink.red, green: ink.green, blue: ink.blue)
        model.fill(at: CGPoint(x: 150, y: 150))
        precondition(!model.canSave && !model.canUndo && !model.canChooseTool)
        model.fill(at: CGPoint(x: 150, y: 150))
        try await wait { !model.isFilling && model.frameRevision == model.editRevision }
        precondition(model.history.operations.count == 2)
        model.undo(); model.redo()
        try await wait { model.frameRevision == model.editRevision }
        let count = model.history.operations.count
        model.fill(at: CGPoint(x: 0, y: 0)); model.cancelFill()
        try await Task.sleep(for: .milliseconds(200))
        precondition(!model.isFilling && model.history.operations.count == count)
        checks.append("Closed-frame fill, same-color no-op, busy guards, undo/redo and cancellation")

        model.chooseTool(.text)
        modal { panel in
            precondition(NSColorPanel.shared.worksWhenModal && NSColorPanel.shared.level == .modalPanel &&
                NSColorPanel.shared.collectionBehavior.contains(.fullScreenAuxiliary))
            let add = button("添加文字", in: panel)
            precondition(!add.isEnabled && !model.canSave && !model.canToggleEditing)
            let text = control("drawing.text.content", in: panel, as: NSTextView.self)
            text.string = "取消时保留原画面"
            text.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: text))
            let size = control("drawing.text.size", in: panel, as: NSTextField.self)
            editField(size, value: "0"); precondition(!add.isEnabled)
            editField(size, value: "32"); precondition(add.isEnabled)
            try! capture("text-input-light", in: panel)
            button("取消", in: panel).performClick(nil)
        }
        model.addText(at: CGPoint(x: 120, y: 120))
        precondition(model.history.operations.count == count)
        modal { panel in
            precondition(NSApp.keyWindow === panel)
            let text = control("drawing.text.content", in: panel, as: NSTextView.self)
            panel.makeFirstResponder(text)
            text.insertText("可撤销输入", replacementRange: NSRange(location: NSNotFound, length: 0))
            text.breakUndoCoalescing()
            precondition(text.undoManager?.canUndo == true)
            delegate.undoEdit()
            precondition(text.string.isEmpty && model.history.operations.count == count)
            text.string = "绘画板\nHello PicGlide"
            text.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: text))
            editField(control("drawing.text.size", in: panel, as: NSTextField.self), value: "48")
            let bold = control("drawing.text.bold", in: panel, as: NSButton.self)
            bold.performClick(nil)
            let color = control("drawing.text.color", in: panel, as: NSColorWell.self)
            color.color = .systemRed
            precondition(!delegate.windowShouldClose(window) && delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
            button("添加文字", in: panel).performClick(nil)
        }
        model.addText(at: CGPoint(x: 120, y: 120))
        try await wait { model.frameRevision == model.editRevision }
        precondition(model.history.operations.count == count + 1 && model.isEditing)
        checks.append("Text dialog validates input, cancels cleanly, supports input undo, Chinese, multiline, bold and color; blocks document close")

        model.chooseTool(.crop); model.pendingCrop = CGRect(x: 50, y: 60, width: 800, height: 600)
        model.applyCrop(); try await wait { model.frameRevision == model.editRevision }
        let crop = model.frame!.bounds
        model.chooseTool(.fill); model.color = .green; model.fill(at: CGPoint(x: 700, y: 500))
        try await wait { !model.isFilling && model.frameRevision == model.editRevision }
        model.chooseTool(.text)
        modal { panel in
            let text = control("drawing.text.content", in: panel, as: NSTextView.self)
            text.string = "角落"; text.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: text))
            button("添加文字", in: panel).performClick(nil)
        }
        model.addText(at: CGPoint(x: crop.maxX - 1, y: crop.maxY - 1))
        try await wait { model.frameRevision == model.editRevision }
        if case let .text(patch) = model.history.operations.last! { precondition(crop.contains(patch.bounds)) }
        else { preconditionFailure("Expected text operation") }
        checks.append("Crop then fill and edge text keep original coordinates and visible text bounds")

        for screen in NSScreen.screens {
            window.setFrame(NSRect(origin: screen.visibleFrame.origin, size: NSSize(width: 620, height: 440)), display: true)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for tool in EditTool.allCases {
                    model.chooseTool(tool); model.setZoom(actualSize: false)
                    try await Task.sleep(for: .milliseconds(100))
                    let canvas = model.canvas!, region = model.toolbarCursorRegion!
                    let rect = canvas.convert(region.cursorRect, from: region)
                    precondition(region.cursorRect.height <= 93 && canvas.viewport.imageRect.intersection(rect).isEmpty,
                        "Tool layout: \(tool.rawValue), toolbar=\(rect), image=\(canvas.viewport.imageRect), canvas=\(canvas.bounds)")
                    precondition(region.convert(region.cursorRect, to: window.contentView!).minX >= 19)
                    if tool == .text || tool == .fill { try capture("drawing-\(theme)-\(screen.localizedName)-\(tool.rawValue)") }
                }
            }
        }
        model.toggleEditing(); model.revealControls()
        try await Task.sleep(for: .milliseconds(200))
        precondition(model.isUntitled && model.toolbarCursorRegion!.cursorRect.width <= 113 && !model.canNavigate)
        try capture("untitled-browse"); model.toggleEditing()
        checks.append("Seven tools fit minimum window, available displays and both themes; fit stays clear of tools; untitled browse has zoom only")

        let png = files.appendingPathComponent("画布.png")
        var leftCanvas = false
        savePanel(to: png, cancel: true); respond("保存")
        model.confirmLeaving { leftCanvas = true }
        // External native-panel interaction includes UI-driver latency, not image-processing time.
        try await wait(timeout: 120) { !model.isBusy }
        precondition(!leftCanvas && model.currentURL == nil && model.canSave)
        var saveResult: Bool?
        savePanel(to: png); model.save { saveResult = $0 }
        try await wait(timeout: 120) { saveResult != nil }
        precondition(saveResult == true && model.currentURL == png && !model.isDirty, "Native first save did not succeed")
        let pngMetadata = try ImageMetadata.read(png)
        precondition(pngMetadata.pixelSize == crop.size)
        let saved = try Data(contentsOf: png), savedOperations = model.history.operations
        model.commit(.pencil([CGPoint(x: 60, y: 80)], ink: ink, width: 6))
        respond("取消"); model.restoreEdits(); precondition(model.isDirty)
        respond("舍弃修改"); model.restoreEdits()
        try await wait { model.frameRevision == model.editRevision }
        let afterRestore = try Data(contentsOf: png)
        precondition(model.history.operations == savedOperations && !model.isDirty && !model.canRedo && afterRestore == saved)
        checks.append("Native first-save cancel preserves canvas; save sets current file; discard restores saved checkpoint without writing")

        model.commit(.pencil([CGPoint(x: 60, y: 80)], ink: ink, width: 6))
        let external = saved + Data([0]); try external.write(to: png)
        var failed = false
        respond("好"); model.save { failed = !$0 }
        try await wait { failed && !model.isSaving }
        let afterFailure = try Data(contentsOf: png)
        precondition(model.isDirty && afterFailure == external)
        for format in [ImageFormat.jpeg, .webp] {
            let target = files.appendingPathComponent("画布-另存." + format.fileExtension)
            savePanel(to: target, format: format); model.save(asCopy: true)
            try await wait(timeout: 120) { !model.isSaving && model.currentURL == target && !model.isDirty }
            let metadata = try ImageMetadata.read(target)
            precondition(metadata.pixelSize == crop.size)
        }
        checks.append("External-change save failure preserves file and edits; native JPEG and WebP Save As become current file")
        window.appearance = NSAppearance(named: .aqua)
        if let screen = window.screen {
            let area = screen.visibleFrame
            window.setFrame(NSRect(x: area.midX - 550, y: area.midY - 380, width: 1100, height: 760), display: true)
        }
        model.setZoom(actualSize: false)
        try await Task.sleep(for: .milliseconds(150)); try capture("drawing-saved")
        let report: [String: Any] = ["checks": checks, "files": files.path,
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "scale": $0.backingScaleFactor] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("drawing-report.json"))
        print("PICGLIDE_DRAWING_PASS \(checks.count) groups"); fflush(stdout)
        if ProcessInfo.processInfo.environment["PICGLIDE_DRAWING_INTERACTIVE"] == "1" { return }
        NSApp.terminate(nil)
    } catch {
        try? error.localizedDescription.write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
        print("PICGLIDE_DRAWING_FAIL \(error)"); fflush(stdout); exit(EXIT_FAILURE)
    }
}
#endif
