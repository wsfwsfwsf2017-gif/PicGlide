import AppKit
import SwiftUI
import PicGlideCore

struct ImageCanvas: NSViewRepresentable {
    let model: ViewerModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.update() }
}

@MainActor
final class CanvasView: NSView {
    let model: ViewerModel
    var viewport = Viewport()
    private var imageID: UUID?
    private var zoomCommandID: UUID?
    private var cancelID: UUID?
    private var fitMode = true
    private var spaceHeld = false
    private var dragStart: CGPoint?
    private var dragPan: CGPoint = .zero
    private var isPanning = false
    private var stroke: [CGPoint] = []
    private var selection: CGRect?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: ViewerModel) {
        self.model = model
        super.init(frame: .zero)
        model.canvas = self
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("图片画布")
        setAccessibilityHelp("拖动移动图片，滚轮缩放，方向键浏览图片。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
    }

    func update() {
        if imageID != model.imageID {
            imageID = model.imageID; fitMode = true
            viewport.pan = .zero; clearGesture()
        }
        if cancelID != model.cancelGestureID {
            cancelID = model.cancelGestureID; clearGesture(); spaceHeld = false
        }
        if let frame = model.frame {
            if model.isEditing { fitMode = false }
            if viewport.imageBounds != frame.bounds {
                if fitMode && !model.isEditing { viewport.imageBounds = frame.bounds; viewport.fit() }
                else { viewport.changeBounds(to: frame.bounds) }
            }
            if let command = model.viewportCommand, zoomCommandID != command.id {
                zoomCommandID = command.id
                fitMode = !command.actualSize
                if fitMode { viewport.fit() }
                else { viewport.scale = 1 / (window?.backingScaleFactor ?? 2); viewport.pan = .zero }
            }
            setAccessibilityLabel(model.currentURL?.lastPathComponent ?? "图片画布")
            notifyZoom()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        viewport.viewSize = bounds.size
        if fitMode { viewport.fit() }
        notifyZoom(); needsDisplay = true
    }

    private func notifyZoom() {
        let scale = viewport.scale, backing = window?.backingScaleFactor ?? 2
        DispatchQueue.main.async { [weak model] in model?.updateZoom(scale: scale, backingScale: backing) }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        for rect in canvasCursorRects { addCursorRect(rect, cursor: canvasCursor) }
    }

    var canvasCursor: NSCursor {
        if model.frame == nil || model.isBusy { return .arrow }
        if isPanning { return .closedHand }
        return !model.isEditing || model.tool == .hand || spaceHeld ? .openHand : .crosshair
    }

    var canvasCursorRects: [NSRect] {
        let area = visibleRect.intersection(bounds)
        guard let toolbar = model.toolbarCursorRegion, toolbar.window === window else { return [area] }
        let overlap = convert(toolbar.cursorRect, from: toolbar).intersection(area)
        guard !overlap.isEmpty else { return [area] }
        return [
            NSRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY),
            NSRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY),
            NSRect(x: area.minX, y: overlap.minY, width: overlap.minX - area.minX, height: overlap.height),
            NSRect(x: overlap.maxX, y: overlap.minY, width: area.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frame = model.frame, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = viewport.imageRect
        context.saveGState()
        context.interpolationQuality = viewport.scale * (window?.backingScaleFactor ?? 2) > 2 ? .none : .high
        if frame.image.alphaInfo != .none && frame.image.alphaInfo != .noneSkipLast && frame.image.alphaInfo != .noneSkipFirst {
            context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            context.fill(rect)
        }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(frame.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()

        if !stroke.isEmpty {
            context.saveGState(); context.clip(to: rect)
            context.setStrokeColor(model.ink.cgColor)
            context.setLineWidth(model.lineWidth * viewport.scale)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.move(to: viewport.viewPoint(from: stroke[0]))
            for point in stroke.dropFirst() { context.addLine(to: viewport.viewPoint(from: point)) }
            context.strokePath(); context.restoreGState()
        }
        if let selection = selection ?? model.pendingCrop {
            let start = viewport.viewPoint(from: selection.origin)
            let drawn = CGRect(x: start.x, y: start.y,
                               width: selection.width * viewport.scale, height: selection.height * viewport.scale)
            context.saveGState()
            if model.tool == .rectangle {
                context.clip(to: rect); context.setStrokeColor(model.ink.cgColor)
                context.setLineWidth(model.lineWidth * viewport.scale); context.stroke(drawn)
            } else {
                if model.tool == .crop {
                    let mask = CGMutablePath(); mask.addRect(rect); mask.addRect(drawn)
                    context.setFillColor(NSColor.black.withAlphaComponent(0.52).cgColor)
                    context.addPath(mask); context.drawPath(using: .eoFill)
                } else {
                    context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor); context.fill(drawn)
                }
                context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1.5)
                context.setLineDash(phase: 0, lengths: [6, 4]); context.stroke(drawn)
            }
            context.restoreGState()
        }
    }

    override func mouseMoved(with event: NSEvent) { model.revealControls() }

    override func mouseDown(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        window?.makeFirstResponder(self); model.revealControls()
        let point = convert(event.locationInWindow, from: nil)
        isPanning = !model.isEditing || model.tool == .hand || spaceHeld
        if isPanning {
            dragStart = point; dragPan = viewport.pan; NSCursor.closedHand.set()
        } else {
            guard viewport.imageRect.contains(point) else { return }
            dragStart = clamped(viewport.imagePoint(from: point))
            model.pendingCrop = nil
            if model.tool == .pencil { stroke = [dragStart!] }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isPanning {
            viewport.pan = CGPoint(x: dragPan.x + point.x - start.x, y: dragPan.y + point.y - start.y)
            fitMode = false
        } else {
            let imagePoint = clamped(viewport.imagePoint(from: point))
            if model.tool == .pencil { stroke.append(imagePoint) }
            else { selection = CGRect(x: min(start.x, imagePoint.x), y: min(start.y, imagePoint.y),
                                      width: abs(start.x - imagePoint.x), height: abs(start.y - imagePoint.y)) }
        }
        model.revealControls(); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        if !isPanning {
            switch model.tool {
            case .pencil: if !stroke.isEmpty { model.commit(.pencil(stroke, ink: model.ink, width: model.lineWidth)) }
            case .crop:
                if let selection {
                    // Round endpoints before making the rect; integral expands floating-point drift by a pixel.
                    let x = selection.minX.rounded(), y = selection.minY.rounded()
                    model.pendingCrop = CGRect(x: x, y: y, width: selection.maxX.rounded() - x,
                        height: selection.maxY.rounded() - y).intersection(viewport.imageBounds)
                }
            case .mosaic:
                if let selection, selection.width >= 1, selection.height >= 1 {
                    model.commit(.mosaic(selection.integral, blockSize: model.blockSize))
                }
            case .rectangle:
                if let selection, selection.width >= 1, selection.height >= 1 {
                    model.commit(.rectangle(selection, ink: model.ink, width: model.lineWidth))
                }
            case .hand: break
            }
        }
        clearGesture(); window?.invalidateCursorRects(for: self); needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        let delta = event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 12 : 1)
        viewport.zoom(by: pow(1.12, max(-12, min(12, delta))), around: convert(event.locationInWindow, from: nil))
        fitMode = false; notifyZoom(); model.revealControls(); needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        viewport.zoom(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
        fitMode = false; notifyZoom(); model.revealControls(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard !model.isBusy else { return }
        model.revealControls()
        switch event.keyCode {
        case 123, 126: model.navigate(-1)
        case 124, 125: model.navigate(1)
        case 49:
            spaceHeld = true; window?.invalidateCursorRects(for: self)
        case 36, 76: model.applyCrop()
        case 53:
            if dragStart != nil || model.pendingCrop != nil { clearGesture(); model.pendingCrop = nil }
            else { model.chooseTool(.hand) }
            needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self) }
        else { super.keyUp(with: event) }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let b = viewport.imageBounds
        return CGPoint(x: min(b.maxX, max(b.minX, point.x)), y: min(b.maxY, max(b.minY, point.y)))
    }

    private func clearGesture() { dragStart = nil; selection = nil; stroke.removeAll(); isPanning = false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedURL(sender).map { ImageFormat.supports($0) ? .copy : [] } ?? []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedURL(sender), ImageFormat.supports(url) else { return false }
        model.requestOpen(url); return true
    }
    private func draggedURL(_ sender: NSDraggingInfo) -> URL? {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? NSURL).map { $0 as URL }
    }
}
