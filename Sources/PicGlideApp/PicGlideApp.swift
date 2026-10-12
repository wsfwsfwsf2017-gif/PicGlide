import AppKit
import SwiftUI

@main @MainActor
enum PicGlideApp {
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.png") { application.applicationIconImage = icon }
        #endif
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = ViewerModel()
    private(set) var window: PicGlideWindow!
    private var allowClose = false
    private var allowTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = PicGlideWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "PicGlide"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 620, height: 440)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.model = model
        window.contentView = NSHostingView(rootView: ViewerView(model: model))
        window.center(); window.setFrameAutosaveName("PicGlideWindow")
        model.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.currentURL == nil, let argument = CommandLine.arguments.dropFirst().first,
           !argument.hasPrefix("-") { model.requestOpen(URL(fileURLWithPath: argument)) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PICGLIDE_SMOKE_OUTPUT"] != nil {
            Task { await runSmokeChecks(delegate: self) }
        }
        #endif
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            model.requestOpen(URL(fileURLWithPath: first))
            window?.makeKeyAndOrderFront(nil)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        guard !model.isBusy else { return .terminateCancel }
        if !model.isDirty { return .terminateNow }
        Task { [weak self] in
            guard let self else { return }
            model.confirmLeaving { [weak self] in self?.allowTermination = true; NSApp.terminate(nil) }
        }
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        guard !model.isBusy else { return false }
        if !model.isDirty { return true }
        model.confirmLeaving { [weak self] in
            self?.allowClose = true; self?.allowTermination = true; sender.close()
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        model.cancelGestureID = UUID()
        model.navigationHover = 0
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); let child = NSMenu(title: title)
            item.submenu = child; main.addItem(item); return child
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", shift: Bool = false) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            entry.target = self
            if shift { entry.keyEquivalentModifierMask = [.command, .shift] }
            menu.addItem(entry)
        }
        let app = menu("PicGlide")
        item(app, "关于 PicGlide", #selector(about))
        app.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 PicGlide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp; app.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]; hideOthers.target = NSApp; app.addItem(hideOthers)
        app.addItem(.separator())
        let quit = NSMenuItem(title: "退出 PicGlide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; app.addItem(quit)
        let file = menu("文件")
        item(file, "打开图片…", #selector(openImage), "o")
        file.addItem(.separator())
        item(file, "保存", #selector(saveImage), "s")
        item(file, "另存为…", #selector(saveCopy), "s", shift: true)
        file.addItem(.separator())
        item(file, "关闭窗口", #selector(closeWindow), "w")
        let edit = menu("编辑")
        item(edit, "撤销", #selector(undoEdit), "z")
        item(edit, "重做", #selector(redoEdit), "z", shift: true)
        edit.addItem(.separator())
        item(edit, "编辑图片", #selector(toggleEdit), "e")
        let view = menu("显示")
        item(view, "适应窗口", #selector(fitImage), "0")
        item(view, "原始尺寸", #selector(actualSize), "1")
        view.addItem(.separator())
        item(view, "上一张", #selector(previousImage))
        item(view, "下一张", #selector(nextImage))
        view.addItem(.separator())
        let fullScreen = NSMenuItem(title: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]; fullScreen.target = nil; view.addItem(fullScreen)
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoEdit): model.canUndo
        case #selector(redoEdit): model.canRedo
        case #selector(saveImage): model.canSave
        case #selector(saveCopy): model.canSaveCopy
        case #selector(toggleEdit), #selector(fitImage), #selector(actualSize): model.frame != nil && !model.isBusy
        case #selector(previousImage): model.index > 0 && !model.isBusy
        case #selector(nextImage): model.index + 1 < model.files.count && !model.isBusy
        default: !model.isBusy
        }
    }

    @objc func openImage() { model.openPanel() }
    @objc func saveImage() { model.save() }
    @objc func saveCopy() { model.save(asCopy: true) }
    @objc func undoEdit() { model.undo() }
    @objc func redoEdit() { model.redo() }
    @objc func toggleEdit() { model.toggleEditing() }
    @objc func fitImage() { model.setZoom(actualSize: false) }
    @objc func actualSize() { model.setZoom(actualSize: true) }
    @objc func previousImage() { model.navigate(-1) }
    @objc func nextImage() { model.navigate(1) }
    @objc func closeWindow() { window.performClose(nil) }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PicGlide",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版",
            .credits: NSAttributedString(string: "轻量看图，随手标注。\nWebP 编码：libwebp（BSD-3-Clause）")
        ])
    }
}

@MainActor
final class PicGlideWindow: NSWindow {
    weak var model: ViewerModel?

    func isHeaderLocation(_ point: NSPoint) -> Bool {
        guard let contentView else { return false }
        let content = contentView.convert(contentView.bounds, to: nil)
        let header = NSRect(x: content.minX, y: content.maxY - 40, width: content.width, height: 40)
        guard header.contains(point) else { return false }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(type), !button.isHidden,
               button.convert(button.bounds, to: nil).insetBy(dx: -3, dy: -3).contains(point) { return false }
        }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isHeaderLocation(event.locationInWindow) {
            if event.clickCount.isMultiple(of: 2) {
                if !styleMask.contains(.fullScreen) { zoom(nil) }
                return
            }
            if !styleMask.contains(.fullScreen) {
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
        switch event.type {
        case .mouseMoved, .leftMouseUp:
            model?.canvas?.updateNavigationHover(at: event.locationInWindow)
            updateCursor(at: event.locationInWindow)
        case .cursorUpdate, .mouseEntered, .mouseExited:
            model?.canvas?.updateNavigationHover(at: mouseLocationOutsideOfEventStream)
            updateCursor(at: mouseLocationOutsideOfEventStream)
        case .leftMouseDragged:
            if model?.canvas?.canvasCursor === NSCursor.closedHand { NSCursor.closedHand.set() }
        default: break
        }
    }

    private func updateCursor(at point: NSPoint) {
        guard isKeyWindow, let canvas = model?.canvas else { return }
        if let contentView, let cursor = CursorRegionView.cursor(at: point, in: contentView) {
            // SwiftUI hosting views can replace cursor rects registered by their transparent backgrounds.
            cursor.set()
        } else if canvas.convert(canvas.visibleRect.intersection(canvas.bounds), to: nil).contains(point) {
            canvas.canvasCursor.set()
        }
    }
}
