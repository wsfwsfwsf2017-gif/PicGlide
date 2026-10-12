import AppKit
import SwiftUI

struct ClickableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(CursorRegion(cursor: .pointingHand))
    }
}

struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    var model: ViewerModel? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CursorRegionView { CursorRegionView(model: model) }
    func updateNSView(_ view: CursorRegionView, context: Context) {
        view.cursor = isEnabled ? cursor : .arrow
        view.refreshCursorRects()
    }
}

@MainActor
final class CursorRegionView: NSView {
    var cursor: NSCursor = .arrow
    var cursorRect: NSRect { visibleRect.intersection(bounds) }
    private weak var model: ViewerModel?

    init(model: ViewerModel?) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() { addCursorRect(cursorRect, cursor: cursor) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshCursorRects() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); refreshCursorRects() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); refreshCursorRects() }

    func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
        guard let model else { return }
        if window != nil { model.toolbarCursorRegion = self }
        else if model.toolbarCursorRegion === self { model.toolbarCursorRegion = nil }
        if let canvas = model.canvas { canvas.window?.invalidateCursorRects(for: canvas) }
    }

    static func cursor(at point: NSPoint, in root: NSView) -> NSCursor? {
        var match: CursorRegionView?
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let region = view as? CursorRegionView,
               region.convert(region.cursorRect, to: nil).contains(point),
               match == nil || region.cursorRect.width * region.cursorRect.height < match!.cursorRect.width * match!.cursorRect.height {
                match = region
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return match?.cursor
    }
}
