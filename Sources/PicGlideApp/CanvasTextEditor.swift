import AppKit
import PicGlideCore

struct CanvasTextDraft {
    let id: UUID
    var content: String
    let origin: CGPoint
    var fontSize: Double
    var bold: Bool
    var ink: Ink

    var isEmpty: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func differs(from original: TextAnnotation?) -> Bool {
        guard let original else { return !isEmpty }
        return content != original.content || fontSize != original.fontSize || bold != original.bold || ink != original.ink
    }

    func patch(within bounds: CGRect) throws -> RenderedImage {
        try ImageRenderer.textPatch(content, at: origin, within: bounds, fontSize: fontSize, bold: bold, ink: ink)
    }
}

@MainActor
final class CanvasTextEditor: NSView, NSTextViewDelegate {
    let id: UUID
    let input = CanvasTextInput()
    private let scroll = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private weak var canvas: CanvasView?

    override var isFlipped: Bool { true }

    init(draft: CanvasTextDraft, canvas: CanvasView) {
        self.id = draft.id; self.canvas = canvas
        super.init(frame: .zero)
        input.string = draft.content
        input.delegate = self
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.textContainerInset = NSSize(width: 5, height: 5)
        input.isHorizontallyResizable = true
        input.isVerticallyResizable = true
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainer?.containerSize = input.maxSize
        input.textContainer?.widthTracksTextView = false
        input.textContainer?.heightTracksTextView = false
        input.textContainer?.lineFragmentPadding = 0
        input.identifier = NSUserInterfaceItemIdentifier("drawing.text.content")
        input.setAccessibilityLabel("画布文字")
        input.setAccessibilityHelp("回车换行，Command 加回车完成，Escape 取消")
        input.setSelectedRange(NSRange(location: (draft.content as NSString).length, length: 0))
        input.finish = { [weak canvas] in _ = canvas?.model.finishTextDraft() }
        input.cancel = { [weak canvas] in canvas?.model.cancelTextDraft() }

        scroll.documentView = input
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1.5
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        scroll.layer?.masksToBounds = true
        addSubview(scroll)
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .labelColor
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = .windowBackgroundColor
        errorLabel.setAccessibilityLabel("文字输入错误")
        addSubview(errorLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func position(draft: CanvasTextDraft, error: String?, in canvas: CanvasView) {
        let area = canvas.visibleRect.intersection(canvas.bounds).insetBy(dx: 8, dy: 8)
        guard area.width > 0, area.height > 0 else { return }
        let font = NSFont.systemFont(ofSize: max(14, min(64, draft.fontSize * canvas.viewport.scale)),
            weight: draft.bold ? .bold : .regular)
        if input.font != font { input.font = font }
        let lines = draft.content.components(separatedBy: .newlines)
        let textWidth = lines.reduce(CGFloat(0)) { width, line in
            max(width, (line as NSString).size(withAttributes: [.font: font]).width)
        }
        let textHeight = ceil((font.ascender - font.descender + font.leading) * CGFloat(lines.count)) + 14
        let width = min(area.width, max(166, min(440, ceil(textWidth) + 16)))
        let inputHeight = min(area.height, max(32, min(148, textHeight)))
        errorLabel.isHidden = error == nil
        errorLabel.stringValue = error ?? ""
        errorLabel.preferredMaxLayoutWidth = width
        let errorHeight = error == nil ? 0 : ceil(errorLabel.fittingSize.height) + 5
        let height = min(area.height, inputHeight + errorHeight)
        let textBounds = canvas.model.textOverlay.annotations[draft.id] == nil ? canvas.model.frame?.bounds : canvas.model.originalBounds
        let placed = textBounds.flatMap { try? ImageRenderer.textBounds(draft.content, at: draft.origin, within: $0,
            fontSize: draft.fontSize, bold: draft.bold) }
        let anchor = canvas.viewport.viewPoint(from: placed?.origin ?? draft.origin)
        frame = canvas.backingAlignedRect(NSRect(x: min(area.maxX - width, max(area.minX, anchor.x)),
            y: min(area.maxY - height, max(area.minY, anchor.y)), width: width, height: height), options: .alignAllEdgesNearest)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, inputHeight))
        input.setFrameSize(NSSize(width: max(scroll.contentSize.width, ceil(textWidth) + 16),
            height: max(scroll.contentSize.height, textHeight)))
        errorLabel.frame = NSRect(x: 0, y: inputHeight + 4, width: bounds.width, height: max(0, height - inputHeight - 4))
    }

    func textDidChange(_ notification: Notification) {
        guard let canvas else { return }
        canvas.model.updateTextContent(input.string)
        canvas.updateTextEditor()
    }
}

@MainActor
final class CanvasTextInput: NSTextView {
    var finish: (() -> Void)?
    var cancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 53 { cancel?(); return }
            if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) { finish?(); return }
        }
        super.keyDown(with: event)
    }
}
