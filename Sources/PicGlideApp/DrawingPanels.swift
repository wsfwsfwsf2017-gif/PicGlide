import AppKit
import PicGlideCore

@MainActor
private func runDrawingPanel(_ panel: NSPanel, for owner: NSWindow?) -> NSApplication.ModalResponse {
    panel.appearance = owner?.effectiveAppearance
    if let owner { owner.beginSheet(panel) } else { panel.center() }
    let response = NSApp.runModal(for: panel)
    if let owner, panel.sheetParent === owner { owner.endSheet(panel) }
    panel.orderOut(nil)
    return response
}

@MainActor
private func panelStack(_ views: [NSView], in panel: NSPanel) {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = panel.contentView!
    content.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
    ])
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
}

@MainActor
final class NewCanvasPanel: NSPanel, NSTextFieldDelegate {
    private let presets = NSSegmentedControl(labels: ["1920 × 1080", "2560 × 1440", "自定义"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let widthField = NSTextField(string: "1920")
    private let heightField = NSTextField(string: "1080")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let create = NSButton(title: "创建", target: nil, action: nil)
    private var result: CanvasSize?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 390, height: 198), styleMask: [.titled], backing: .buffered, defer: false)
        title = "新建画布"; isReleasedWhenClosed = false
        presets.target = self; presets.action = #selector(selectPreset(_:)); presets.selectedSegment = 0
        presets.identifier = NSUserInterfaceItemIdentifier("drawing.canvas.preset")
        for (field, name) in [(widthField, "width"), (heightField, "height")] {
            field.delegate = self; field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
            field.identifier = NSUserInterfaceItemIdentifier("drawing.canvas." + name)
            field.setAccessibilityLabel(name == "width" ? "画布宽度" : "画布高度")
        }
        let dimensions = NSStackView(views: [NSTextField(labelWithString: "宽"), widthField,
            NSTextField(labelWithString: "×"), NSTextField(labelWithString: "高"), heightField,
            NSTextField(labelWithString: "px")])
        dimensions.spacing = 8
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true
        create.target = self; create.action = #selector(confirm(_:)); create.bezelStyle = .rounded
        create.keyEquivalent = "\r"; create.identifier = NSUserInterfaceItemIdentifier("drawing.canvas.create")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, create]); buttons.spacing = 8
        panelStack([presets, dimensions, errorLabel, buttons], in: self)
        validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func run(for owner: NSWindow?) -> CanvasSize? {
        runDrawingPanel(self, for: owner) == .OK ? result : nil
    }
    private func size() throws -> CanvasSize {
        guard let width = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces)),
              let height = Int(heightField.stringValue.trimmingCharacters(in: .whitespaces)) else { throw DrawingError.invalidCanvasSize }
        return try CanvasSize(width: width, height: height)
    }
    private func validate() {
        do { _ = try size(); create.isEnabled = true; errorLabel.stringValue = "" }
        catch { create.isEnabled = false; errorLabel.stringValue = error.localizedDescription }
    }
    @objc private func selectPreset(_ sender: NSSegmentedControl) {
        if sender.selectedSegment < 2 {
            widthField.stringValue = sender.selectedSegment == 0 ? "1920" : "2560"
            heightField.stringValue = sender.selectedSegment == 0 ? "1080" : "1440"
        } else { makeFirstResponder(widthField); widthField.selectText(nil) }
        validate()
    }
    func controlTextDidChange(_ notification: Notification) { presets.selectedSegment = 2; validate() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField,
              selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        let delta = selector == #selector(NSResponder.moveUp(_:)) ? 1 : -1
        field.stringValue = String(min(8192, max(1, (Int(field.stringValue) ?? 1) + delta)))
        presets.selectedSegment = 2; validate(); return true
    }
    @objc private func confirm(_ sender: Any?) {
        guard let size = try? size() else { validate(); return }
        result = size; NSApp.stopModal(withCode: .OK)
    }
    @objc private func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}

@MainActor
final class TextDrawingPanel: NSPanel, NSTextViewDelegate, NSTextFieldDelegate {
    private let textView = NSTextView()
    private let sizeField = NSTextField(string: "32")
    private let stepper = NSStepper()
    private let colorButton = PaletteColorButton()
    private let boldButton = NSButton(checkboxWithTitle: "加粗", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let add = NSButton(title: "添加文字", target: nil, action: nil)
    private let point: CGPoint
    private let imageBounds: CGRect
    private var result: RenderedImage?
    var fontSize: Double { Double(sizeField.stringValue) ?? .nan }
    var bold: Bool { boldButton.state == .on }
    var selectedColor: NSColor { colorButton.color }

    init(at point: CGPoint, within bounds: CGRect, color: NSColor, fontSize: Double, bold: Bool) {
        self.point = point; self.imageBounds = bounds
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 290), styleMask: [.titled], backing: .buffered, defer: false)
        title = "添加文字"; isReleasedWhenClosed = false
        textView.isRichText = false; textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13); textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.identifier = NSUserInterfaceItemIdentifier("drawing.text.content"); textView.setAccessibilityLabel("文字内容")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = textView; scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        textView.frame = NSRect(x: 0, y: 0, width: 340, height: 120)
        colorButton.color = color
        colorButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorButton.identifier = NSUserInterfaceItemIdentifier("drawing.text.color"); colorButton.setAccessibilityLabel("文字颜色")
        sizeField.stringValue = String(Int(fontSize)); sizeField.delegate = self; sizeField.alignment = .right
        sizeField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        sizeField.identifier = NSUserInterfaceItemIdentifier("drawing.text.size"); sizeField.setAccessibilityLabel("字号（像素）")
        stepper.minValue = 8; stepper.maxValue = 512; stepper.increment = 1; stepper.doubleValue = fontSize
        stepper.target = self; stepper.action = #selector(stepSize(_:)); stepper.setAccessibilityLabel("调整字号")
        boldButton.state = bold ? .on : .off; boldButton.target = self; boldButton.action = #selector(styleChanged(_:))
        boldButton.identifier = NSUserInterfaceItemIdentifier("drawing.text.bold")
        let style = NSStackView(views: [NSTextField(labelWithString: "颜色"), colorButton,
            NSTextField(labelWithString: "字号"), sizeField, stepper, boldButton]); style.spacing = 8
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true
        add.target = self; add.action = #selector(confirm(_:)); add.bezelStyle = .rounded
        add.keyEquivalent = "\r"; add.keyEquivalentModifierMask = [.command]
        add.identifier = NSUserInterfaceItemIdentifier("drawing.text.add")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, add]); buttons.spacing = 8
        panelStack([scroll, style, errorLabel, buttons], in: self)
        initialFirstResponder = textView; validate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func run(for owner: NSWindow?) -> RenderedImage? {
        defer { colorButton.closePalette() }
        return runDrawingPanel(self, for: owner) == .OK ? result : nil
    }
    private func validate() {
        guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            add.isEnabled = false; errorLabel.stringValue = ""; return
        }
        do {
            _ = try ImageRenderer.textBounds(textView.string, at: point, within: imageBounds, fontSize: fontSize, bold: bold)
            add.isEnabled = true; errorLabel.stringValue = ""
            stepper.doubleValue = fontSize
        } catch { add.isEnabled = false; errorLabel.stringValue = error.localizedDescription }
    }
    @objc private func styleChanged(_ sender: Any?) { validate() }
    @objc private func stepSize(_ sender: NSStepper) { sizeField.stringValue = String(sender.integerValue); validate() }
    func textDidChange(_ notification: Notification) { validate() }
    func controlTextDidChange(_ notification: Notification) { validate() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        let current = fontSize.isFinite ? fontSize : 32
        sizeField.stringValue = String(Int(min(512, max(8, current + (selector == #selector(NSResponder.moveUp(_:)) ? 1 : -1)))))
        validate(); return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textView.hasMarkedText(), [36, 53, 76].contains(event.keyCode) { return false }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func confirm(_ sender: Any?) {
        guard !textView.hasMarkedText() else { return }
        do {
            let rgb = selectedColor.usingColorSpace(.sRGB) ?? .black
            result = try ImageRenderer.textPatch(textView.string, at: point, within: imageBounds,
                fontSize: fontSize, bold: bold, ink: Ink(red: rgb.redComponent, green: rgb.greenComponent,
                    blue: rgb.blueComponent, alpha: rgb.alphaComponent))
            NSApp.stopModal(withCode: .OK)
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
    @objc private func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}
