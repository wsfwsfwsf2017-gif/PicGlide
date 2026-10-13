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
    private var pointer: CGPoint?
    private var cropAdjustment: CropAdjustment?
    private var cropStart: CGRect?
    private(set) var cropControls: NSHostingView<CropControls>?
    var mosaicPreview: CGImage? { mosaicFrame?.image }
    private var mosaicFrame: RenderedImage?
    private var completedMosaics: [(revision: Int, operations: [EditOperation])] = []
    private var pendingMosaics: [(id: UUID, points: [CGPoint], diameter: Double, blockSize: Double)] = []
    private var mosaicTask: Task<Void, Never>?
    private var mosaicID = UUID()
    private var mosaicTaskID = UUID()
    private var strokeDiameter: Double = 20
    private var strokeBlockSize: Double = 24
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
            cancelPendingMosaics()
            completedMosaics.removeAll()
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
        updateCropControls()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        viewport.viewSize = bounds.size
        if fitMode { viewport.fit() }
        notifyZoom(); updateCropControls(); needsDisplay = true
    }

    private func notifyZoom() {
        let scale = viewport.scale, backing = window?.backingScaleFactor ?? 2
        DispatchQueue.main.async { [weak model] in model?.updateZoom(scale: scale, backingScale: backing) }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        for rect in canvasCursorRects { addCursorRect(rect, cursor: canvasCursor) }
    }

    var canvasCursor: NSCursor {
        if model.frame == nil || model.isBusy { return .arrow }
        if isPanning { return .closedHand }
        if !model.isEditing || model.tool == .hand || spaceHeld { return .openHand }
        if model.tool == .crop, let adjustment = cropAdjustment ?? pointer.flatMap(cropHit) {
            switch adjustment {
            case .move: return dragStart == nil ? .openHand : .closedHand
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .bottomRight: return Self.diagonalDown
            case .topRight, .bottomLeft: return Self.diagonalUp
            }
        }
        return .crosshair
    }

    private static let diagonalDown = diagonalCursor("arrow.up.left.and.arrow.down.right")
    private static let diagonalUp = diagonalCursor("arrow.up.right.and.arrow.down.left")
    private static func diagonalCursor(_ symbol: String) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let shadow = NSShadow(); shadow.shadowColor = .white; shadow.shadowBlurRadius = 2; shadow.set()
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.draw(in: rect.insetBy(dx: 3, dy: 3))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    func trackPointer(at point: NSPoint) {
        let local = convert(point, from: nil)
        let overControl = window?.contentView.flatMap { CursorRegionView.cursor(at: point, in: $0) } != nil
        pointer = bounds.contains(local) && !overControl && window?.isKeyWindow == true ? local : nil
        needsDisplay = true
    }

    var canvasCursorRects: [NSRect] {
        let area = visibleRect.intersection(bounds)
        guard let root = window?.contentView else { return [area] }
        let exclusions = CursorRegionView.regions(in: root).map { convert($0.cursorRect, from: $0) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        var rects = [area]
        for exclusion in exclusions {
            rects = rects.flatMap { rect in
                let overlap = exclusion.intersection(rect)
                guard !overlap.isEmpty else { return [rect] }
                return [
                    NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    NSRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    NSRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
                ].filter { !$0.isEmpty }
            }
        }
        return rects
    }

    func updateNavigationHover(at point: NSPoint) {
        let local = convert(point, from: nil)
        let overToolbar = model.toolbarCursorRegion.map { $0.convert($0.cursorRect, to: nil).contains(point) } ?? false
        var direction = 0
        if window?.isKeyWindow == true, bounds.contains(local), model.files.count > 1,
           !model.isEditing, !model.isBusy, !isPanning, !overToolbar {
            if local.x < 72 { direction = -1 }
            else if local.x > bounds.maxX - 72 { direction = 1 }
        }
        if model.navigationHover != direction { model.navigationHover = direction }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frame = model.frame, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = viewport.imageRect
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = viewport.scale * (window?.backingScaleFactor ?? 2) > 2 ? .none : .high
        if frame.image.alphaInfo != .none && frame.image.alphaInfo != .noneSkipLast && frame.image.alphaInfo != .noneSkipFirst {
            context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            context.fill(rect)
        }
        completedMosaics.removeAll {
            $0.revision <= model.frameRevision || !model.history.operations.starts(with: $0.operations)
        }
        let paintingMosaic = !completedMosaics.isEmpty || (model.tool == .mosaic && !stroke.isEmpty && mosaicFrame != nil)
        if paintingMosaic { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(frame.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()

        for completed in completedMosaics {
            if let operation = completed.operations.last {
                drawMosaic(operation, in: context)
            }
        }
        if model.tool == .mosaic, !stroke.isEmpty, let mosaicFrame {
            drawMosaic(.mosaic(stroke, diameter: strokeDiameter, blockSize: strokeBlockSize, patch: mosaicFrame), in: context)
        }
        if paintingMosaic { context.endTransparencyLayer() }
        context.restoreGState()

        if model.tool == .pencil, !stroke.isEmpty {
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
                }
                context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1.5)
                context.stroke(drawn)
                if model.tool == .crop {
                    for handle in CropAdjustment.allCases where handle != .move {
                        let point = viewport.viewPoint(from: handle.point(in: selection))
                        let box = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                        context.setFillColor(NSColor.white.cgColor); context.fill(box)
                        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                        context.setLineWidth(1); context.stroke(box)
                    }
                }
            }
            context.restoreGState()
        }

        if model.isEditing, model.tool == .mosaic, !model.isBusy, !spaceHeld, !isPanning,
           let pointer, rect.contains(pointer) {
            let diameter = (dragStart == nil ? model.mosaicDiameter : strokeDiameter) * viewport.scale
            let ring = CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2, width: diameter, height: diameter)
            context.saveGState(); context.clip(to: bounds)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor); context.setLineWidth(3)
            context.strokeEllipse(in: ring)
            context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1)
            context.strokeEllipse(in: ring); context.restoreGState()
        }
    }

    private func drawMosaic(_ operation: EditOperation, in context: CGContext) {
        guard case let .mosaic(points, diameter, _, patch) = operation else { return }
        let origin = viewport.viewPoint(from: .zero)
        let transform = CGAffineTransform(a: viewport.scale, b: 0, c: 0, d: viewport.scale, tx: origin.x, ty: origin.y)
        context.saveGState(); context.clip(to: viewport.imageRect)
        ImageRenderer.drawMosaic(points: points, diameter: diameter, patch: patch, in: context, transform: transform)
        context.restoreGState()
    }

    override func mouseMoved(with event: NSEvent) { trackPointer(at: event.locationInWindow); model.revealControls() }
    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }

    private func cropHit(_ point: CGPoint) -> CropAdjustment? {
        guard let rect = model.pendingCrop else { return nil }
        let handles = CropAdjustment.allCases.filter { $0 != .move }
        let nearest = handles.min {
            let a = viewport.viewPoint(from: $0.point(in: rect)), b = viewport.viewPoint(from: $1.point(in: rect))
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }!
        let handlePoint = viewport.viewPoint(from: nearest.point(in: rect))
        if hypot(handlePoint.x - point.x, handlePoint.y - point.y) <= 10 { return nearest }
        return rect.contains(viewport.imagePoint(from: point)) ? .move : nil
    }

    func updateCropControls() {
        guard model.isEditing, model.tool == .crop, let rect = model.pendingCrop,
              rect.width >= 1, rect.height >= 1 else {
            cropControls?.removeFromSuperview(); cropControls = nil
            return
        }
        if cropControls == nil {
            let view = NSHostingView(rootView: CropControls(model: model))
            view.sizingOptions = []
            cropControls = view; addSubview(view)
        }
        let controls = cropControls!
        controls.isHidden = dragStart != nil || model.isBusy
        let area = visibleRect.intersection(bounds).insetBy(dx: 8, dy: 8)
        guard area.width >= 140, area.height >= 48 else { controls.isHidden = true; return }
        let first = viewport.viewPoint(from: rect.origin)
        let selected = CGRect(x: first.x, y: first.y, width: rect.width * viewport.scale, height: rect.height * viewport.scale)
        let toolbar = model.toolbarCursorRegion.map { convert($0.cursorRect, from: $0).insetBy(dx: -10, dy: -10) } ?? .zero
        let origins = [
            CGPoint(x: selected.maxX - 140, y: selected.maxY + 12),
            CGPoint(x: selected.maxX - 140, y: selected.minY - 60),
            CGPoint(x: selected.maxX - 152, y: selected.minY + 12),
            CGPoint(x: selected.maxX - 140, y: toolbar.minY - 60)
        ]
        let candidates = origins.map { point in
            CGRect(x: min(area.maxX - 140, max(area.minX, point.x)),
                   y: min(area.maxY - 48, max(area.minY, point.y)), width: 140, height: 48)
        }
        let fitting = origins.map { CGRect(origin: $0, size: NSSize(width: 140, height: 48)) }
            .first { area.contains($0) && !$0.intersects(toolbar) }
        controls.frame = fitting ?? candidates.first(where: { !$0.intersects(toolbar) }) ?? candidates.last!
        window?.invalidateCursorRects(for: self)
    }

    private func prepareMosaicPreview() {
        guard mosaicTask == nil else { return }
        let token = UUID(); mosaicTaskID = token
        mosaicTask = Task { [weak self, model] in
            do {
                while !Task.isCancelled {
                    guard let self, mosaicTaskID == token else { return }
                    let pending = pendingMosaics.first
                    if pending == nil && (dragStart == nil || stroke.isEmpty || model.tool != .mosaic || mosaicFrame != nil) { break }
                    let id = pending?.id ?? mosaicID, blockSize = pending?.blockSize ?? strokeBlockSize
                    let image = try await model.makeMosaicPreview(blockSize: blockSize)
                    guard !Task.isCancelled, mosaicTaskID == token else { return }
                    if pendingMosaics.first?.id == id {
                        let finished = pendingMosaics.removeFirst()
                        try commitMosaic(finished.points, diameter: finished.diameter, blockSize: finished.blockSize, preview: image)
                        model.pendingMosaicCount = pendingMosaics.count
                    } else if mosaicID == id, dragStart != nil, model.tool == .mosaic {
                        mosaicFrame = image; needsDisplay = true
                    }
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, mosaicTaskID == token else { return }
                cancelPendingMosaics(); clearGesture(); model.showError(error)
            }
            guard let self, mosaicTaskID == token else { return }
            mosaicTask = nil
        }
    }

    private func commitMosaic(_ points: [CGPoint], diameter: Double, blockSize: Double, preview: RenderedImage) throws {
        let patch = try ImageRenderer.mosaicPatch(from: preview, points: points, diameter: diameter)
        if let revision = model.commit(.mosaic(points, diameter: diameter, blockSize: blockSize, patch: patch)) {
            completedMosaics.append((revision, model.history.operations))
            needsDisplay = true
        }
    }

    func cancelPendingMosaics() {
        pendingMosaics.removeAll(); model.pendingMosaicCount = 0
        mosaicTask?.cancel(); mosaicTask = nil; mosaicTaskID = UUID()
    }

    override func mouseDown(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        window?.makeFirstResponder(self); model.revealControls()
        model.navigationHover = 0
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        isPanning = !model.isEditing || model.tool == .hand || spaceHeld
        guard isPanning || model.tool == .mosaic || model.pendingMosaicCount == 0 else { return }
        if isPanning {
            dragStart = point; dragPan = viewport.pan; NSCursor.closedHand.set()
        } else {
            let hit = model.tool == .crop ? cropHit(point) : nil
            guard viewport.imageRect.contains(point) || hit != nil else { return }
            dragStart = viewport.imagePoint(from: point)
            model.isDrawing = true
            if model.tool == .crop {
                cropAdjustment = hit; cropStart = model.pendingCrop
                if hit == nil { dragStart = clamped(dragStart!); model.pendingCrop = nil }
            } else {
                model.pendingCrop = nil
                if model.tool == .pencil { stroke = [clamped(dragStart!)] }
                if model.tool == .mosaic {
                    mosaicID = UUID()
                    stroke = [dragStart!]; strokeDiameter = model.mosaicDiameter; strokeBlockSize = model.blockSize
                    prepareMosaicPreview()
                }
            }
            canvasCursor.set()
        }
        updateCropControls(); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if isPanning {
            viewport.pan = CGPoint(x: dragPan.x + point.x - start.x, y: dragPan.y + point.y - start.y)
            fitMode = false
        } else {
            let imagePoint = viewport.imagePoint(from: point)
            if model.tool == .pencil { stroke.append(clamped(imagePoint)) }
            else if model.tool == .mosaic { if stroke.last != imagePoint { stroke.append(imagePoint) } }
            else if let cropAdjustment, let cropStart {
                selection = cropAdjustment.applying(to: cropStart,
                    delta: CGPoint(x: imagePoint.x - start.x, y: imagePoint.y - start.y), within: viewport.imageBounds)
                model.pendingCrop = selection
            }
            else { selection = CGRect(x: min(start.x, imagePoint.x), y: min(start.y, imagePoint.y),
                                      width: abs(start.x - imagePoint.x), height: abs(start.y - imagePoint.y)).intersection(viewport.imageBounds)
                if selection?.isEmpty == true { selection = nil }
                if model.tool == .crop { model.pendingCrop = selection }
            }
        }
        model.revealControls(); updateCropControls(); needsDisplay = true
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
                    let rounded = CGRect(x: x, y: y, width: selection.maxX.rounded() - x,
                        height: selection.maxY.rounded() - y).intersection(viewport.imageBounds)
                    model.pendingCrop = rounded.width >= 1 && rounded.height >= 1 ? rounded : nil
                }
            case .mosaic:
                let last = viewport.imagePoint(from: convert(event.locationInWindow, from: nil))
                if stroke.last != last { stroke.append(last) }
                if !stroke.isEmpty {
                    if let mosaicFrame, pendingMosaics.isEmpty {
                        do { try commitMosaic(stroke, diameter: strokeDiameter, blockSize: strokeBlockSize, preview: mosaicFrame) }
                        catch { model.showError(error) }
                    } else {
                        pendingMosaics.append((mosaicID, stroke, strokeDiameter, strokeBlockSize))
                        model.pendingMosaicCount = pendingMosaics.count
                    }
                }
            case .rectangle:
                if let selection, selection.width >= 1, selection.height >= 1 {
                    model.commit(.rectangle(selection, ink: model.ink, width: model.lineWidth))
                }
            case .hand: break
            }
        }
        clearGesture()
        if !pendingMosaics.isEmpty { prepareMosaicPreview() }
        updateCropControls(); window?.invalidateCursorRects(for: self); needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        let delta = event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 12 : 1)
        viewport.zoom(by: pow(1.12, max(-12, min(12, delta))), around: convert(event.locationInWindow, from: nil))
        fitMode = false; notifyZoom(); updateCropControls(); model.revealControls(); needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard model.frame != nil, !model.isBusy else { return }
        viewport.zoom(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
        fitMode = false; notifyZoom(); updateCropControls(); model.revealControls(); needsDisplay = true
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
            if model.isEditing && model.tool == .crop { clearGesture(); model.cancelCrop() }
            else if dragStart != nil { clearGesture() }
            else if !pendingMosaics.isEmpty {
                pendingMosaics.removeLast(); model.pendingMosaicCount = pendingMosaics.count
                if pendingMosaics.isEmpty { cancelPendingMosaics() }
            }
            else { model.chooseTool(.hand) }
            updateCropControls(); window?.invalidateCursorRects(for: self); needsDisplay = true
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

    private func clearGesture() {
        dragStart = nil; selection = nil; stroke.removeAll(); isPanning = false
        cropAdjustment = nil; cropStart = nil; model.isDrawing = false
        if pendingMosaics.isEmpty { cancelPendingMosaics() }
        mosaicID = UUID(); mosaicFrame = nil
    }

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
