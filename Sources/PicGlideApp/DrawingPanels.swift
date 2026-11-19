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
