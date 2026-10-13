import AppKit
import SwiftUI

// The type alias selects the property wrapper even when newer SDKs also expose a State macro.
private typealias HoverState = SwiftUI.State<Bool>

struct ClickableButtonStyle: ButtonStyle {
    var selected = false
    var prominent = false
    var help: String = ""

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, selected: selected, prominent: prominent, help: help)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let prominent: Bool
        let help: String
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @HoverState private var hovered = false

        private var fill: Color {
            guard isEnabled else { return .clear }
            if prominent { return .accentColor.opacity(configuration.isPressed ? 0.75 : hovered ? 0.9 : 1) }
            if selected { return .accentColor.opacity(configuration.isPressed ? 0.2 : hovered ? 0.17 : 0.12) }
            return .primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(prominent && isEnabled ? Color.white : selected ? Color.accentColor : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 8).fill(fill)
                }
                .opacity(isEnabled ? 1 : 0.35)
                .background(CursorRegion(cursor: .pointingHand, help: help))
                .accessibilityHint(help)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }
    }
}

struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    var model: ViewerModel? = nil
    var help: String = ""
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CursorRegionView { CursorRegionView(model: model) }
    func updateNSView(_ view: CursorRegionView, context: Context) {
        view.cursor = isEnabled ? cursor : .arrow
        view.helpText = help
        view.refreshCursorRects()
    }
}

@MainActor
final class CursorRegionView: NSView, NSViewToolTipOwner {
    var cursor: NSCursor = .arrow
    var helpText = ""
    var cursorRect: NSRect { visibleRect.intersection(bounds) }
    private weak var model: ViewerModel?
    private weak var tooltipHost: NSView?
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipRect = NSRect.zero
    private var tooltipText = ""

    init(model: ViewerModel?) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() { addCursorRect(cursorRect, cursor: cursor) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let tooltipTag {
            tooltipHost?.removeToolTip(tooltipTag)
            self.tooltipTag = nil; tooltipHost = nil; tooltipText = ""; tooltipRect = .zero
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshCursorRects() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); refreshCursorRects() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refreshCursorRects() }

    func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
        refreshTooltip()
        guard let model else { return }
        if window != nil { model.toolbarCursorRegion = self }
        else if model.toolbarCursorRegion === self { model.toolbarCursorRegion = nil }
        if let canvas = model.canvas {
            canvas.window?.invalidateCursorRects(for: canvas)
            canvas.updateCropControls()
        }
    }

    func refreshTooltip() {
        let host = window?.contentView
        let rect = host.map { convert(cursorRect, to: $0).intersection($0.visibleRect) } ?? .zero
        let text = !helpText.isEmpty && (window as? PicGlideWindow)?.model?.isBusy == true
            ? "\(helpText)\n图片正在处理，请稍候。" : helpText
        guard host !== tooltipHost || !rect.equalTo(tooltipRect) || text != tooltipText else { return }
        if let tooltipTag { tooltipHost?.removeToolTip(tooltipTag) }
        tooltipTag = nil; tooltipHost = host; tooltipRect = rect; tooltipText = text
        if let host, !rect.isEmpty, !text.isEmpty {
            // The transparent cursor view is excluded from hit testing; register help on its hosting view.
            tooltipTag = host.addToolTip(rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String { tooltipText }

    static func regions(in view: NSView) -> [CursorRegionView] {
        guard !view.isHidden else { return [] }
        return ((view as? CursorRegionView).map { [$0] } ?? []) + view.subviews.flatMap { regions(in: $0) }
    }

    static func cursor(at point: NSPoint, in root: NSView) -> NSCursor? {
        regions(in: root).filter { $0.convert($0.cursorRect, to: nil).contains(point) }
            .min { $0.cursorRect.width * $0.cursorRect.height < $1.cursorRect.width * $1.cursorRect.height }?.cursor
    }
}
