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
    func respondToAlert(_ title: String) {
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated {
                @MainActor func findButton(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == title { return button }
                    return view.subviews.compactMap(findButton).first
                }
                guard let view = NSApp.modalWindow?.contentView, let button = findButton(in: view) else {
                    preconditionFailure("Expected confirmation button: \(title)")
                }
                button.performClick(nil)
                try? title.write(to: output.appendingPathComponent("dialog-response.txt"), atomically: true, encoding: .utf8)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    func checkFileActions() {
        let root = window.contentView!, bounds = window.contentView!.convert(window.contentView!.bounds, to: nil)
        let actions = CursorRegionView.regions(in: root).filter {
            let rect = $0.convert($0.cursorRect, to: nil)
            return abs(rect.height - 32) < 0.1 && rect.minY >= bounds.maxY - 40
        }.sorted { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }
        precondition(actions.count == 4, "File actions are hidden or clipped")
        let enabled = [model.canToggleEditing,
                       model.canRestore, model.canSaveCopy, model.canSave]
        var previousMaxX: CGFloat = 78
        for (index, action) in actions.enumerated() {
            let rect = action.convert(action.cursorRect, to: nil)
            precondition(rect.minX >= previousMaxX && rect.maxX <= bounds.maxX - 19,
                         "File actions overlap or leave the window")
            precondition(action.cursor === (enabled[index] ? NSCursor.pointingHand : NSCursor.arrow),
                         "File action disabled state is incorrect")
            precondition(!window.isHeaderLocation(NSPoint(x: rect.midX, y: rect.midY)),
                         "Window drag intercepts a file action")
            previousMaxX = rect.maxX
        }
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
        model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
        let originalFile = try Data(contentsOf: fixture)
        model.commit(.rectangle(CGRect(x: 50, y: 60, width: 100, height: 80), ink: model.ink, width: 4))
        model.commit(.rectangle(CGRect(x: 200, y: 200, width: 80, height: 70), ink: model.ink, width: 3))
        model.undo(); try await wait { model.frameRevision == model.editRevision }
        precondition(model.canUndo && model.canRedo)
        let previousEdits = model.history.operations
        model.chooseTool(.crop)
        let pending = model.frame!.bounds.insetBy(dx: 20, dy: 20)
        model.pendingCrop = pending
        let frameBeforePixelChecks = window.frame
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            window.setFrame(NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                width: 1100, height: 760), display: true)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                model.pendingCrop = CGRect(x: 600, y: 200, width: 309, height: 188)
                model.setZoom(actualSize: false)
                try await Task.sleep(for: .milliseconds(100))
                let canvas = model.canvas!
                canvas.viewport.pan.x += 0.27; canvas.viewport.pan.y += 0.39
                canvas.updateCropControls()
                let panel = canvas.cropControls!, pixels = canvas.convertToBacking(panel.frame)
                let record: [String: Any] = ["scenario": "crop text pixel alignment", "theme": theme,
                    "screen": screen.localizedName, "backingScale": window.backingScaleFactor,
                    "framePixels": [pixels.minX, pixels.minY, pixels.width, pixels.height],
                    "layerScale": panel.layer?.contentsScale ?? 0]
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("crop-text-\(theme)-\(screenIndex).json"))
                try capture("crop-text-\(theme)-\(screenIndex)")
                precondition([pixels.minX, pixels.minY, pixels.width, pixels.height].allSatisfy {
                    abs($0 - $0.rounded()) < 0.001
                }, "Crop controls are placed between physical pixels: \(pixels)")
                precondition(canvas.bounds.contains(panel.frame), "Aligned crop controls leave the canvas")
                records.append(record)
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        window.setFrame(frameBeforePixelChecks, display: true)
        model.pendingCrop = pending
        model.setZoom(actualSize: false)
        model.chooseTool(.pencil)
        precondition(model.pendingCrop == pending && model.tool == .crop,
                     "Switching tools silently discards an unconfirmed crop")
        model.toggleEditing()
        precondition(model.pendingCrop == pending && model.isEditing,
                     "Hiding editing tools silently discards an unconfirmed crop")
        model.undo(); model.redo(); model.navigate(1)
        precondition(model.history.operations == previousEdits && model.pendingCrop == pending &&
                     !model.canUndo && !model.canRedo && !model.canNavigate && !model.canToggleEditing &&
                     !model.canChooseTool && !model.canSave && !model.canSaveCopy && model.canRestore,
                     "Pending crop permits a destructive state transition")
        for action in [#selector(AppDelegate.toggleEdit), #selector(AppDelegate.undoEdit), #selector(AppDelegate.redoEdit),
                       #selector(AppDelegate.saveImage), #selector(AppDelegate.saveCopy),
                       #selector(AppDelegate.previousImage), #selector(AppDelegate.nextImage)] {
            precondition(!delegate.validateMenuItem(NSMenuItem(title: "检查", action: action, keyEquivalent: "")))
        }
        try await Task.sleep(for: .milliseconds(100)); checkFileActions()
        respondToAlert("继续编辑")
        precondition(!delegate.windowShouldClose(window))
        respondToAlert("继续编辑")
        model.requestOpen(fixture, fillWindow: false)
        let fileAfterCanceledLeave = try Data(contentsOf: fixture)
        precondition(model.pendingCrop == pending && model.history.operations == previousEdits &&
                     fileAfterCanceledLeave == originalFile)
        records.append(["scenario": "pending crop blocks tool, history, navigation, save and hide; canceled close and external open preserve edits"])

        model.cancelCrop()
        precondition(model.pendingCrop == nil && model.tool == .hand && model.isEditing &&
                     model.history.operations == previousEdits && model.canUndo && model.canRedo)
        model.save(); try await wait { !model.isSaving && !model.isDirty }
        precondition(model.isEditing && model.history.operations == previousEdits)
        let savedFile = try Data(contentsOf: fixture)
        let editMenu = NSMenuItem(title: "编辑", action: #selector(AppDelegate.toggleEdit), keyEquivalent: "e")
        precondition(delegate.validateMenuItem(editMenu) && editMenu.state == .on && editMenu.title == "收起编辑工具")
        records.append(["scenario": "cancel crop preserves committed edits; save keeps editing tools open"])

        model.commit(.rectangle(CGRect(x: 400, y: 200, width: 100, height: 90), ink: model.ink, width: 3))
        try await wait { model.frameRevision == model.editRevision }
        let unsavedEdits = model.history.operations
        model.toggleEditing()
        let fileAfterHidingTools = try Data(contentsOf: fixture)
        precondition(!model.isEditing && model.isDirty && model.history.operations == unsavedEdits &&
                     fileAfterHidingTools == savedFile)
        respondToAlert("取消"); model.restoreEdits()
        precondition(model.history.operations == unsavedEdits && !model.isEditing)
        respondToAlert("舍弃修改"); model.restoreEdits()
        try await wait { model.frameRevision == model.editRevision }
        let fileAfterDiscard = try Data(contentsOf: fixture)
        precondition(!model.isEditing && !model.isDirty && model.history.operations == previousEdits &&
                     !model.history.canRedo && fileAfterDiscard == savedFile)
        precondition(delegate.validateMenuItem(editMenu) && editMenu.state == .off && editMenu.title == "展开编辑工具")
        records.append(["scenario": "hiding tools never saves; discard cancel and saved checkpoint restore preserve browsing mode"])

        model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
        model.chooseTool(.crop); model.pendingCrop = pending
        precondition(!model.isDirty && model.needsLeaveConfirmation)
        respondToAlert("继续编辑")
        precondition(!delegate.windowShouldClose(window))
        let responseFile = output.appendingPathComponent("dialog-response.txt")
        try FileManager.default.removeItem(at: responseFile)
        respondToAlert("继续编辑")
        precondition(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        try await wait { FileManager.default.fileExists(atPath: responseFile.path) && NSApp.modalWindow == nil }
        precondition(model.pendingCrop == pending && !model.isDirty && model.isEditing)
        records.append(["scenario": "crop-only document requires close and quit confirmation"])

        model.applyCrop(); try await wait { model.frameRevision == model.editRevision }
        let fileAfterCrop = try Data(contentsOf: fixture)
        precondition(model.tool == .hand && model.isEditing && model.isDirty &&
                     model.history.operations.count == previousEdits.count + 1 && model.frame?.bounds == pending &&
                     fileAfterCrop == savedFile)
        model.undo(); try await wait { model.frameRevision == model.editRevision }
        precondition(!model.isDirty && model.history.operations == previousEdits)
        records.append(["scenario": "crop commits one undoable operation without saving"])

        model.chooseTool(.crop); model.pendingCrop = pending
        respondToAlert("舍弃修改并继续")
        model.requestOpen(fixture, fillWindow: false)
        try await wait { model.frame != nil && !model.isLoading }
        let fileAfterOpening = try Data(contentsOf: fixture)
        precondition(model.pendingCrop == nil && !model.isDirty && !model.isEditing &&
                     fileAfterOpening == savedFile)
        records.append(["scenario": "explicitly discarding crop allows external open without writing the file"])

        let failureFixture = output.appendingPathComponent("save-failure-fixture.png")
        try savedFile.write(to: failureFixture)
        model.requestOpen(failureFixture, fillWindow: false)
        try await wait { model.frame != nil && !model.isLoading }
        model.toggleEditing(); try await wait { model.isEditing && !model.isPreparingEdit }
        model.commit(.rectangle(CGRect(x: 400, y: 200, width: 90, height: 80), ink: model.ink, width: 3))
        try await wait { model.frameRevision == model.editRevision }
        let failedEdits = model.history.operations
        let changedFile = savedFile + Data([0])
        try changedFile.write(to: failureFixture, options: .atomic)
        var saveFailed = false
        respondToAlert("好")
        model.save { saveFailed = !$0 }
        try await wait { saveFailed && !model.isSaving }
        let fileAfterFailure = try Data(contentsOf: failureFixture)
        precondition(model.isEditing && model.isDirty && model.history.operations == failedEdits && fileAfterFailure == changedFile)
        records.append(["scenario": "failed save preserves unsaved edits and externally changed file"])
        respondToAlert("不保存"); model.requestOpen(fixture, fillWindow: false)
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
                checkFileActions()
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
                    checkFileActions()
                    records.append(["theme": dark ? "dark" : "light", "window": [size.width, size.height],
                        "tool": tool.rawValue, "imageFitsCanvas": fits, "imageOverlapsToolbar": overlaps,
                        "fileActionsVisible": true])
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
