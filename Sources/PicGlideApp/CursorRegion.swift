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
final class CursorRegionView: NSView {
    var cursor: NSCursor = .arrow
    var helpText = ""
    var cursorRect: NSRect { visibleRect.intersection(bounds) }
    private weak var model: ViewerModel?
    var tooltipText: String {
        !helpText.isEmpty && (window as? PicGlideWindow)?.model?.isBusy == true
            ? "\(helpText)\n图片正在处理，请稍候。" : helpText
    }

    init(model: ViewerModel?) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() { addCursorRect(cursorRect, cursor: cursor) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { (window as? PicGlideWindow)?.hideTooltip() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshCursorRects() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); refreshCursorRects() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refreshCursorRects() }

    func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
        (window as? PicGlideWindow)?.refreshTooltip()
        guard let model else { return }
        if window != nil { model.toolbarCursorRegion = self }
        else if model.toolbarCursorRegion === self { model.toolbarCursorRegion = nil }
        if let canvas = model.canvas {
            canvas.window?.invalidateCursorRects(for: canvas)
            canvas.updateCropControls()
        }
    }

    static func regions(in view: NSView) -> [CursorRegionView] {
        guard !view.isHidden else { return [] }
        return ((view as? CursorRegionView).map { [$0] } ?? []) + view.subviews.flatMap { regions(in: $0) }
    }

    static func region(at point: NSPoint, in root: NSView) -> CursorRegionView? {
        regions(in: root).filter { $0.convert($0.cursorRect, to: nil).contains(point) }
            .min { $0.cursorRect.width * $0.cursorRect.height < $1.cursorRect.width * $1.cursorRect.height }
    }

    static func cursor(at point: NSPoint, in root: NSView) -> NSCursor? { region(at: point, in: root)?.cursor }
}

@MainActor
final class TooltipPanel: NSPanel {
    private(set) var text = ""
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = true; hidesOnDeactivate = true; isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(for region: CursorRegionView) {
        guard let owner = region.window, !region.cursorRect.isEmpty else { return }
        text = region.tooltipText
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 280
        let fitted = label.fittingSize
        let size = NSSize(width: ceil(fitted.width) + 16, height: ceil(fitted.height) + 12)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover; background.state = .active; background.wantsLayer = true
        background.layer?.cornerRadius = 6; background.layer?.masksToBounds = true
        label.frame = NSRect(x: 8, y: 6, width: size.width - 16, height: size.height - 12)
        background.addSubview(label); contentView = background; appearance = owner.effectiveAppearance
        let anchor = owner.convertToScreen(region.convert(region.cursorRect, to: nil))
        let area = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let y = anchor.maxY + 6 + size.height <= area.maxY ? anchor.maxY + 6 : anchor.minY - size.height - 6
        let origin = NSPoint(x: min(max(area.minX, anchor.midX - size.width / 2), area.maxX - size.width),
                             y: min(max(area.minY, y), area.maxY - size.height))
        setFrame(NSRect(origin: origin, size: size), display: true)
        if parent !== owner {
            parent?.removeChildWindow(self)
            owner.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }
}
