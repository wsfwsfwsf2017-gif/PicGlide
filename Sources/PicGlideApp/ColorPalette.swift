import AppKit
import SwiftUI

struct SimpleColorPicker: NSViewRepresentable {
    let color: NSColor
    let label: String
    let onChange: (NSColor) -> Void
    let onClose: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> PaletteColorButton { PaletteColorButton() }
    func updateNSView(_ button: PaletteColorButton, context: Context) {
        button.color = color
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier("parameter.color")
        button.onChange = onChange
        button.onClose = onClose
        if !isEnabled { button.closePalette() }
    }
}

private func paletteRGB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat = 1) -> NSColor {
    let rgb = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    return NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: alpha)
}

@MainActor
final class PaletteColorButton: NSButton, NSPopoverDelegate {
    var color: NSColor = .black {
        didSet { image = Self.swatch(color); palette?.refresh(color) }
    }
    var onChange: ((NSColor) -> Void)?
    var onClose: (() -> Void)?
    private(set) var popover: NSPopover?
    private(set) var palette: ColorPaletteController?
    private weak var previousResponder: NSResponder?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        bezelStyle = .rounded; imagePosition = .imageOnly; title = ""
        image = Self.swatch(color)
        target = self; action = #selector(showPalette(_:))
        setAccessibilityLabel("颜色"); setAccessibilityHelp("颜色与透明度")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showPalette(_ sender: Any?) {
        guard isEnabled, let window else { return }
        if popover?.isShown == true { closePalette(); return }
        previousResponder = window.firstResponder
        let palette = ColorPaletteController(color: color) { [weak self] color in
            self?.color = color; self?.onChange?(color)
        }
        let popover = NSPopover()
        popover.behavior = .transient; popover.animates = false
        popover.contentViewController = palette; popover.appearance = effectiveAppearance
        popover.delegate = self
        palette.dismiss = { [weak self] in self?.closePalette() }
        self.palette = palette; self.popover = popover
        (window as? PicGlideWindow)?.hideTooltip()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
    func closePalette() { popover?.close() }
    func popoverDidShow(_ notification: Notification) {
        let window = palette?.view.window
        (window as? NSPanel)?.worksWhenModal = true
        window?.makeFirstResponder(palette?.colorBoard)
    }
    func popoverDidClose(_ notification: Notification) {
        if let previous = previousResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
        palette = nil; popover = nil; previousResponder = nil
        onClose?()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { closePalette() }
        super.viewWillMove(toWindow: newWindow)
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 30, height: 16), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            shape.addClip()
            NSColor.white.setFill(); rect.fill()
            NSColor(white: 0.76, alpha: 1).setFill()
            for y in stride(from: 0, to: 16, by: 4) {
                for x in stride(from: 0, to: 30, by: 4) where (x / 4 + y / 4) % 2 == 0 {
                    NSRect(x: x, y: y, width: 4, height: 4).fill()
                }
            }
            color.setFill(); rect.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.14).setStroke(); shape.lineWidth = 1; shape.stroke()
            return true
        }
    }
}

@MainActor
final class ColorPaletteController: NSViewController, NSTextFieldDelegate {
    let colorBoard = PaletteGradientView(isHue: false)
    let hueBand = PaletteGradientView(isHue: true)
    let numberFields = (0..<4).map { _ in NSTextField(string: "0") }
    private var color: NSColor
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 0
    private let onChange: (NSColor) -> Void
    var dismiss: (() -> Void)?

    init(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.color = color; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 396, height: 228))
        colorBoard.onSelect = { [weak self] x, y in self?.select(saturation: x, brightness: 1 - y) }
        hueBand.onSelect = { [weak self] x, _ in
            guard let self else { return }
            hue = x
            select(saturation: saturation == 0 ? 1 : saturation, brightness: brightness == 0 ? 1 : brightness)
        }
        colorBoard.dismiss = { [weak self] in self?.dismiss?() }
        hueBand.dismiss = { [weak self] in self?.dismiss?() }
        let board = NSStackView(views: [colorBoard, hueBand])
        board.orientation = .vertical; board.spacing = 4
        colorBoard.widthAnchor.constraint(equalToConstant: 232).isActive = true
        colorBoard.heightAnchor.constraint(equalToConstant: 174).isActive = true
        hueBand.widthAnchor.constraint(equalToConstant: 232).isActive = true
        hueBand.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let fields = NSStackView(); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 12
        for (index, name) in ["R", "G", "B", "透明度"].enumerated() {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12); label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 38).isActive = true
            let field = numberFields[index]
            field.tag = index; field.delegate = self; field.alignment = .right
            field.bezelStyle = .roundedBezel
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
            field.identifier = NSUserInterfaceItemIdentifier("palette." + ["red", "green", "blue", "opacity"][index])
            field.setAccessibilityLabel(["红色（0–255）", "绿色（0–255）", "蓝色（0–255）", "透明度（0–100%）"][index])
            let unit = NSTextField(labelWithString: index == 3 ? "%" : "")
            unit.font = .systemFont(ofSize: 11); unit.widthAnchor.constraint(equalToConstant: 12).isActive = true
            let row = NSStackView(views: [label, field, unit]); row.spacing = 4
            fields.addArrangedSubview(row)
        }
        let stack = NSStackView(views: [board, fields]); stack.spacing = 12; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        refresh(color)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ color: NSColor) {
        self.color = color.usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        self.color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Preserve the chosen hue while the selection is black, white or gray.
        if s > 0 && v > 0 { hue = h }
        saturation = s; brightness = v
        colorBoard.update(hue: hue, saturation: s, brightness: v)
        hueBand.update(hue: hue, saturation: s, brightness: v)
        let values = componentValues
        for (index, field) in numberFields.enumerated() where field.currentEditor() == nil {
            field.stringValue = String(values[index])
        }
    }
    private var componentValues: [Int] {
        [color.redComponent * 255, color.greenComponent * 255, color.blueComponent * 255, color.alphaComponent * 100]
            .map { Int($0.rounded()) }
    }
    private func select(saturation: CGFloat, brightness: CGFloat) {
        let rgb = paletteRGB(hue: hue, saturation: saturation, brightness: brightness, alpha: color.alphaComponent)
        publish(NSColor(srgbRed: (rgb.redComponent * 255).rounded() / 255,
            green: (rgb.greenComponent * 255).rounded() / 255,
            blue: (rgb.blueComponent * 255).rounded() / 255, alpha: color.alphaComponent))
    }
    private func publish(_ selected: NSColor) { refresh(selected); onChange(selected) }
    @discardableResult private func commit(_ field: NSTextField) -> Bool {
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              (0...(field.tag == 3 ? 100 : 255)).contains(value) else { return false }
        var values = componentValues; values[field.tag] = value
        publish(NSColor(srgbRed: CGFloat(values[0]) / 255, green: CGFloat(values[1]) / 255,
            blue: CGFloat(values[2]) / 255, alpha: CGFloat(values[3]) / 100))
        return true
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField { commit(field) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if !commit(field) { NSSound.beep() }
        field.stringValue = String(componentValues[field.tag])
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let delta = selector == #selector(NSResponder.moveUp(_:)) ? 1 : -1
            let limit = field.tag == 3 ? 100 : 255
            let current = min(limit, max(0, Int(field.stringValue) ?? componentValues[field.tag]))
            field.stringValue = String(min(limit, max(0, current + delta)))
            commit(field); field.selectText(nil); return true
        case #selector(NSResponder.insertNewline(_:)):
            if commit(field) { dismiss?() } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = String(componentValues[field.tag]); dismiss?(); return true
        default: return false
        }
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor
final class PaletteGradientView: NSView {
    private let isHue: Bool
    private(set) var hue: CGFloat = 0
    private(set) var saturation: CGFloat = 0
    private(set) var brightness: CGFloat = 0
    var onSelect: ((CGFloat, CGFloat) -> Void)?
    var dismiss: (() -> Void)?
    var selectionRect: NSRect { bounds.insetBy(dx: 6, dy: 4) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    #if DEBUG
    private(set) var mouseSelections = 0
    #endif

    init(isHue: Bool) {
        self.isHue = isHue
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(isHue ? "色相渐变" : "渐变色板")
        setAccessibilityHelp("点击或拖动选色，方向键微调；也可使用右侧数值输入框。")
        identifier = NSUserInterfaceItemIdentifier(isHue ? "palette.hue" : "palette.board")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = selectionRect, shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        context.saveGState(); shape.addClip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors: [CGColor] = isHue ? (0...6).map { paletteRGB(hue: CGFloat($0) / 6, saturation: 1, brightness: 1).cgColor }
            : [NSColor.white.cgColor, paletteRGB(hue: hue, saturation: 1, brightness: 1).cgColor]
        context.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!,
            start: NSPoint(x: rect.minX, y: rect.minY), end: NSPoint(x: rect.maxX, y: rect.minY), options: [])
        if !isHue {
            let shade = CGGradient(colorsSpace: space, colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor] as CFArray, locations: nil)!
            context.drawLinearGradient(shade, start: NSPoint(x: rect.minX, y: rect.minY),
                end: NSPoint(x: rect.minX, y: rect.maxY), options: [])
        }
        context.restoreGState()
        NSColor.black.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 1; shape.stroke()
        let point = NSPoint(x: rect.minX + (isHue ? hue : saturation) * rect.width,
            y: isHue ? rect.midY : rect.minY + (1 - brightness) * rect.height)
        let marker = isHue ? NSBezierPath(roundedRect: NSRect(x: point.x - 3, y: rect.minY - 2, width: 6, height: rect.height + 4), xRadius: 2, yRadius: 2)
            : NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        NSColor.black.withAlphaComponent(0.65).setStroke(); marker.lineWidth = 3; marker.stroke()
        NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()
    }
    override func resetCursorRects() { if !visibleRect.isEmpty { addCursorRect(visibleRect, cursor: .crosshair) } }
    private func choose(_ event: NSEvent) {
        #if DEBUG
        mouseSelections += 1
        #endif
        let point = convert(event.locationInWindow, from: nil), rect = selectionRect
        guard rect.width > 0 && rect.height > 0 else { return }
        onSelect?(min(1, max(0, (point.x - rect.minX) / rect.width)), min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); choose(event) }
    override func mouseDragged(with event: NSEvent) { choose(event) }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = isHue ? 1 / 360 : 1 / 255
        switch event.keyCode {
        case 123: onSelect?(max(0, (isHue ? hue : saturation) - step), 1 - brightness)
        case 124: onSelect?(min(1, (isHue ? hue : saturation) + step), 1 - brightness)
        case 125 where !isHue: onSelect?(saturation, min(1, 1 - brightness + step))
        case 126 where !isHue: onSelect?(saturation, max(0, 1 - brightness - step))
        case 53: dismiss?()
        default: super.keyDown(with: event)
        }
    }
}
