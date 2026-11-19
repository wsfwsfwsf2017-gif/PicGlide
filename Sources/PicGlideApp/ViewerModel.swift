import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import PicGlideCore

enum EditTool: String, CaseIterable {
    case hand, mosaic, crop, rectangle, pencil, fill, text
    var title: String {
        switch self { case .hand: "拖动"; case .mosaic: "马赛克"; case .crop: "裁剪"
        case .rectangle: "画框"; case .pencil: "铅笔"; case .fill: "涂色"; case .text: "文字" }
    }
    var symbol: String {
        switch self { case .hand: "hand.raised"; case .mosaic: "square.grid.3x3"
        case .crop: "crop"; case .rectangle: "rectangle"; case .pencil: "pencil.tip"
        case .fill: "drop.fill"; case .text: "character.textbox" }
    }
}

@MainActor @Observable
final class ViewerModel {
    var frame: RenderedImage?
    var metadata: ImageMetadata?
    private(set) var originalBounds: CGRect?
    var currentURL: URL?
    var imageID = UUID()
    var files: [URL] = []
    var history = EditHistory() {
        didSet { textOverlay = TextOverlay(history.operations) }
    }
    private(set) var textOverlay = TextOverlay([])
    var selectedTextID: UUID?
    private(set) var textDraft: CanvasTextDraft?
    private(set) var textStylePreview: (id: UUID, annotation: TextAnnotation)?
    private(set) var textError: String?
    private(set) var editRevision = 0
    private(set) var frameRevision = 0
    var isLoading = false
    var isSaving = false
    var isPreparingEdit = false
    private(set) var isCreatingCanvas = false
    private(set) var isFilling = false
    private var isShowingPanel = false
    var isEditing = false
    var tool: EditTool = .hand
    var color = Color(red: 0.24, green: 0.64, blue: 1)
    var lineWidth: Double = 6
    var opacity: Double = 1
    var blockSize: Double = 24
    var mosaicDiameter = EditOperation.defaultMosaicDiameter
    private var textSize: Double = 32
    private var textBold = false
    var isDrawing = false
    var pendingMosaicCount = 0
    var pendingCrop: CGRect?
    var cancelGestureID = UUID()
    var viewportCommand: (id: UUID, actualSize: Bool)?
    var zoomPercentage: Double = 100
    var controlsVisible = true
    var toolbarHovered = false
    var toolbarFocused = false
    var toolbarMenuTracking = false
    var navigationHover = 0
    var loadingError: String?
    var savedFeedback = false
    weak var window: PicGlideWindow?
    @ObservationIgnored weak var canvas: CanvasView?
    @ObservationIgnored weak var toolbarCursorRegion: CursorRegionView?

    private let loader = ImageLoader()
    private var source: CGImage?
    private var fingerprint: FileFingerprint?
    private var saveFormat: ImageFormat?
    private var multiFrame = false
    private var generation = UUID()
    private var requestedDimension = 2048
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var renderTask: Task<RenderedImage, Error>?
    private var resolutionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var savedFeedbackTask: Task<Void, Never>?
    private var fillTask: Task<RenderedImage?, Error>?
    private var fillID = UUID()

    var index: Int { currentURL.flatMap { files.firstIndex(of: $0) } ?? 0 }
    var isUntitled: Bool { frame != nil && currentURL == nil }
    var documentName: String { currentURL?.lastPathComponent ?? "未命名" }
    var isDirty: Bool { isUntitled || history.isDirty || hasTextChanges }
    var isBusy: Bool { isSaving || isPreparingEdit || isCreatingCanvas || isFilling || isShowingPanel }
    var needsLeaveConfirmation: Bool { isDirty || pendingCrop != nil }
    var canToggleEditing: Bool { frame != nil && !isBusy && !isDrawing && pendingMosaicCount == 0 && pendingCrop == nil }
    var canChooseTool: Bool { !isBusy && pendingCrop == nil }
    var canNavigate: Bool { currentURL != nil && !files.isEmpty && !isBusy && !isDrawing && pendingMosaicCount == 0 && pendingCrop == nil }
    var canUndo: Bool { history.canUndo && textDraft == nil && !isBusy && pendingMosaicCount == 0 && pendingCrop == nil }
    var canRedo: Bool { history.canRedo && textDraft == nil && !isBusy && pendingMosaicCount == 0 && pendingCrop == nil }
    var canSave: Bool { isDirty && !isBusy && !isDrawing && pendingMosaicCount == 0 && pendingCrop == nil }
    var canSaveCopy: Bool { frame != nil && !isBusy && !isDrawing && pendingMosaicCount == 0 && pendingCrop == nil }
    var canRestore: Bool { frame != nil && !isBusy && (history.isDirty || hasTextChanges || pendingCrop != nil || isDrawing || pendingMosaicCount > 0) }
    let editorPanelHeight: CGFloat = 48
    var canSelectText: Bool { isEditing && (tool == .hand || tool == .text) && pendingMosaicCount == 0 }
    var selectedText: TextAnnotation? { selectedTextID.flatMap { textOverlay.annotations[$0] } }
    var parameterTool: EditTool { tool == .hand && selectedText != nil ? .text : tool }
    var parameterInk: Ink {
        if parameterTool == .text { return textDraft?.ink ?? textStylePreview?.annotation.ink ?? selectedText?.ink ?? ink }
        return ink
    }
    var parameterTextSize: Double { textDraft?.fontSize ?? textStylePreview?.annotation.fontSize ?? selectedText?.fontSize ?? textSize }
    var parameterTextBold: Bool { textDraft?.bold ?? textStylePreview?.annotation.bold ?? selectedText?.bold ?? textBold }

    private var hasTextChanges: Bool {
        textStylePreview != nil || (textDraft.map { $0.differs(from: textOverlay.annotations[$0.id]) } ?? false)
    }
    var undoTitle: String { history.operationToUndo.map { "撤销" + $0.title } ?? "撤销" }
    var redoTitle: String { history.operationToRedo.map { "重做" + $0.title } ?? "重做" }
    var restoreHelp: String {
        if isBusy { return "处理中" }
        return canRestore ? "舍弃修改" : "没有修改"
    }
    var editHelp: String {
        if isBusy || pendingMosaicCount > 0 { return "处理中" }
        if pendingCrop != nil { return "先确认裁剪" }
        if isDrawing { return "绘制中" }
        return isEditing ? "收起编辑工具（⌘E）" : "展开编辑工具（⌘E）"
    }
    var saveHelp: String {
        if isBusy || pendingMosaicCount > 0 { return "处理中" }
        if pendingCrop != nil { return "先确认裁剪" }
        if isDrawing { return "绘制中" }
        return isDirty ? "保存（⌘S）" : "没有修改"
    }
    var ink: Ink {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return Ink(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: opacity)
    }
    var dimensions: String {
        guard let bounds = frame?.bounds else { return "" }
        return "\(Int(bounds.width)) × \(Int(bounds.height))"
    }

    private var canHideControls: Bool {
        frame != nil && !isEditing && !toolbarHovered && !toolbarFocused && !toolbarMenuTracking &&
            !isBusy && canvas?.hasActiveGesture != true && NSApp.modalWindow == nil
    }

    func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        guard canHideControls else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, canHideControls else { return }
            window?.hideTooltip()
            controlsVisible = false
        }
    }

    func requestOpen(_ input: URL, fillWindow: Bool = true) {
        guard !isBusy else { NSSound.beep(); return }
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard ImageFormat.supports(url) else { showError(PicGlideError.unsupportedFormat); return }
        confirmLeaving { [weak self] in self?.open(url, fillWindow: fillWindow) }
    }

    func navigate(_ offset: Int) {
        guard !files.isEmpty, canNavigate else { return }
        let next = index + offset
        guard files.indices.contains(next) else { revealControls(); return }
        requestOpen(files[next], fillWindow: false)
    }

    func openPanel() {
        guard !isBusy, pendingMosaicCount == 0 else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFormat.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择图片，使用方向键浏览同文件夹的其他图片。"
        if panel.runModal() == .OK, let url = panel.url { requestOpen(url) }
    }

    private func open(_ url: URL, fillWindow: Bool) {
        loadTask?.cancel(); preloadTask?.cancel(); renderTask?.cancel(); resolutionTask?.cancel()
        renderTask = nil; resolutionTask = nil; preloadTask = nil
        generation = UUID(); imageID = UUID(); cancelGestureID = UUID()
        let token = generation
        currentURL = url; frame = nil; metadata = nil; source = nil; originalBounds = nil
        savedFeedbackTask?.cancel(); savedFeedback = false
        fingerprint = nil; history = EditHistory(); pendingCrop = nil
        clearTextEditing()
        editRevision = 0; frameRevision = 0
        pendingMosaicCount = 0
        isEditing = false; tool = .hand; isLoading = true; loadingError = nil
        requestedDimension = 2048
        revealControls()
        loadTask = Task { [weak self, loader] in
            do {
                let (metadata, frame, files) = try await loader.load(url)
                guard let self, generation == token, !Task.isCancelled else { return }
                self.metadata = metadata; self.frame = frame; self.files = files
                originalBounds = metadata.bounds
                fingerprint = metadata.fingerprint
                saveFormat = ImageFormat.from(type: metadata.typeIdentifier)
                multiFrame = metadata.frameCount > 1
                isLoading = false
                if fillWindow { window?.fillScreen() }
                window?.title = url.lastPathComponent + " — PicGlide"
                window?.isDocumentEdited = false
                let neighbours = [index - 1, index + 1].filter { files.indices.contains($0) }.map { files[$0] }
                preloadTask = Task { await loader.preload(neighbours) }
                revealControls()
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                isLoading = false; loadingError = error.localizedDescription
            }
        }
    }

    func toggleEditing() {
        guard canToggleEditing else { return }
        if isEditing {
            guard finishTextDraft() else { return }
            selectedTextID = nil
            isEditing = false; tool = .hand; cancelGestureID = UUID()
            revealControls(); return
        }
        if source != nil { isEditing = true; revealControls(); return }
        if let frame, let metadata, frame.bounds == metadata.bounds,
           frame.image.width == Int(metadata.pixelSize.width), frame.image.height == Int(metadata.pixelSize.height) {
            source = frame.image; isEditing = true; revealControls(); return
        }
        guard let url = currentURL, let metadata, let fingerprint else { return }
        isPreparingEdit = true; revealControls()
        let token = generation
        Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    guard try FileFingerprint.read(url) == fingerprint else { throw PicGlideError.externallyChanged }
                    let image = try ImageCodec.decode(url, maxDimension: Int(max(metadata.pixelSize.width, metadata.pixelSize.height)))
                    guard try FileFingerprint.read(url) == fingerprint else { throw PicGlideError.externallyChanged }
                    return image
                }.value
                guard let self, generation == token else { return }
                source = image; isPreparingEdit = false; isEditing = true; revealControls()
            } catch {
                guard let self, generation == token else { return }
                isPreparingEdit = false; showError(error)
            }
        }
    }

    func chooseTool(_ next: EditTool) {
        guard canChooseTool else { return }
        if next == .text, textDraft != nil { canvas?.focusTextInput(); return }
        guard finishTextDraft() else { return }
        if next != tool { selectedTextID = nil }
        tool = next; cancelGestureID = UUID(); revealControls()
    }

    func newCanvasPanel() {
        guard !isBusy, pendingMosaicCount == 0 else { NSSound.beep(); return }
        isShowingPanel = true
        let size = NewCanvasPanel().run(for: window)
        isShowingPanel = false
        if let size { createCanvas(size) }
        else { revealControls() }
    }

    func createCanvas(_ size: CanvasSize) {
        confirmLeaving { [weak self] in self?.prepareCanvas(size) }
    }

    private func prepareCanvas(_ size: CanvasSize) {
        isCreatingCanvas = true; revealControls()
        Task { [weak self] in
            do {
                let (base, preview) = try await Task.detached(priority: .userInitiated) {
                    let image = try size.makeImage()
                    let preview = try ImageRenderer.render(source: image, originalBounds: size.bounds,
                        operations: [], maxDimension: 2048)
                    return (RenderedImage(image: image, bounds: size.bounds), preview)
                }.value
                guard let self else { return }
                loadTask?.cancel(); preloadTask?.cancel(); renderTask?.cancel(); resolutionTask?.cancel()
                savedFeedbackTask?.cancel(); canvas?.cancelPendingMosaics()
                generation = UUID(); imageID = UUID(); cancelGestureID = UUID()
                source = base.image; originalBounds = base.bounds; frame = preview
                metadata = nil; currentURL = nil; files = []; fingerprint = nil; saveFormat = nil; multiFrame = false
                history = EditHistory(); editRevision = 0; frameRevision = 0
                clearTextEditing()
                pendingCrop = nil; pendingMosaicCount = 0; isDrawing = false
                isLoading = false; isCreatingCanvas = false; loadingError = nil; savedFeedback = false
                requestedDimension = 2048; viewportCommand = nil
                isEditing = true; tool = .pencil; color = .black; lineWidth = 6; opacity = 1
                textSize = 32; textBold = false
                window?.title = "未命名 — PicGlide"; window?.isDocumentEdited = true
                window?.makeFirstResponder(canvas); revealControls()
            } catch {
                guard let self else { return }
                isCreatingCanvas = false; showError(error); revealControls()
            }
        }
    }

    func fill(at point: CGPoint) {
        guard isEditing, canChooseTool, pendingMosaicCount == 0, !isDrawing,
              let source, let originalBounds else { return }
        let ink = self.ink
        let operations = history.operations, token = generation, revision = editRevision
        let id = UUID(); fillID = id; isFilling = true; revealControls()
        let task = Task.detached(priority: .userInitiated) {
            let rendered = try ImageRenderer.render(source: source, originalBounds: originalBounds,
                operations: operations, includeText: false)
            return try ImageRenderer.fillMask(in: rendered, at: point, ink: ink)
        }
        fillTask = task
        Task { [weak self] in
            do {
                let mask = try await task.value
                guard let self, fillID == id, generation == token, editRevision == revision, !task.isCancelled else { return }
                fillTask = nil; isFilling = false
                if let mask { commit(.fill(mask: mask, ink: ink)) }
            } catch {
                guard let self, fillID == id else { return }
                fillTask = nil; isFilling = false
                if !(error is CancellationError) { showError(error) }
            }
        }
    }

    func cancelFill() {
        fillID = UUID(); fillTask?.cancel(); fillTask = nil; isFilling = false
    }

    func beginText(at point: CGPoint, editing id: UUID? = nil) {
        guard isEditing, canChooseTool, !isDrawing, pendingMosaicCount == 0,
              let bounds = frame?.bounds, bounds.contains(point), finishTextDraft() else { return }
        let id = id ?? UUID()
        let annotation = textOverlay.annotations[id]
        tool = .text
        textDraft = CanvasTextDraft(id: id, content: annotation?.content ?? "", origin: annotation?.patch.bounds.origin ?? point,
            fontSize: annotation?.fontSize ?? textSize, bold: annotation?.bold ?? textBold, ink: annotation?.ink ?? ink)
        selectedTextID = annotation == nil ? nil : id
        canvas?.updateTextEditor()
        canvas?.focusTextInput()
        revealControls()
    }

    func updateTextContent(_ content: String) {
        guard let textDraft, textDraft.content != content else { return }
        self.textDraft?.content = content
        textError = nil
        window?.isDocumentEdited = isDirty
    }

    func setParameterColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        if parameterTool == .text {
            changeTextStyle(ink: Ink(red: rgb.redComponent, green: rgb.greenComponent,
                blue: rgb.blueComponent, alpha: rgb.alphaComponent))
        } else {
            self.color = Color(nsColor: rgb.withAlphaComponent(1))
            opacity = rgb.alphaComponent
        }
    }

    func changeTextStyle(fontSize: Double? = nil, bold: Bool? = nil, ink: Ink? = nil) {
        if var draft = textDraft {
            draft.fontSize = fontSize ?? draft.fontSize
            draft.bold = bold ?? draft.bold
            draft.ink = ink ?? draft.ink
            textDraft = draft
            textError = nil
        } else if let id = selectedTextID, let original = selectedText, let bounds = originalBounds {
            var annotation = textStylePreview?.annotation ?? original
            annotation.fontSize = fontSize ?? annotation.fontSize
            annotation.bold = bold ?? annotation.bold
            annotation.ink = ink ?? annotation.ink
            if annotation.fontSize == original.fontSize, annotation.bold == original.bold, annotation.ink == original.ink {
                textStylePreview = nil
            } else {
                do {
                    annotation.patch = try ImageRenderer.textPatch(annotation.content, at: original.patch.bounds.origin,
                        within: bounds, fontSize: annotation.fontSize, bold: annotation.bold, ink: annotation.ink)
                    textStylePreview = (id, annotation)
                } catch {
                    NSSound.beep()
                    return
                }
            }
        } else {
            textSize = fontSize ?? textSize
            textBold = bold ?? textBold
            if let ink { setDefaultInk(ink) }
        }
        window?.isDocumentEdited = isDirty
        canvas?.updateTextEditor()
        canvas?.needsDisplay = true
    }

    func finishTextStyle() {
        guard let preview = textStylePreview,
              commit(.text(id: preview.id, annotation: preview.annotation)) != nil else { return }
        textStylePreview = nil
    }

    func finishTextAtBlankClick() {
        if let input = canvas?.textEditor?.input, input.hasMarkedText() {
            input.unmarkText()
            input.inputContext?.discardMarkedText()
            updateTextContent(input.string)
        }
        guard finishTextDraft() else { return }
        selectedTextID = nil
        canvas?.needsDisplay = true
    }

    @discardableResult
    func finishTextDraft() -> Bool {
        finishTextStyle()
        guard let draft = textDraft else { return true }
        guard canvas?.textEditor?.input.hasMarkedText() != true else { canvas?.focusTextInput(); return false }
        let original = textOverlay.annotations[draft.id]
        if draft.differs(from: original) {
            if draft.isEmpty {
                guard commit(.text(id: draft.id, annotation: nil)) != nil else { return false }
                selectedTextID = nil
            } else {
                guard let bounds = original == nil ? frame?.bounds : originalBounds else { return false }
                do {
                    let patch = try draft.patch(within: bounds)
                    let annotation = TextAnnotation(content: draft.content, fontSize: draft.fontSize,
                        bold: draft.bold, ink: draft.ink, patch: patch)
                    guard commit(.text(id: draft.id, annotation: annotation)) != nil else { return false }
                    selectedTextID = draft.id
                    textSize = draft.fontSize; textBold = draft.bold
                    setDefaultInk(draft.ink)
                } catch {
                    textError = error.localizedDescription
                    canvas?.updateTextEditor()
                    canvas?.focusTextInput()
                    return false
                }
            }
        }
        cancelTextDraft()
        return true
    }

    func cancelTextDraft() {
        textDraft = nil
        textError = nil
        canvas?.updateTextEditor()
        canvas?.needsDisplay = true
        window?.isDocumentEdited = isDirty
    }

    private func setDefaultInk(_ ink: Ink) {
        color = Color(red: ink.red, green: ink.green, blue: ink.blue)
        opacity = ink.alpha
    }

    private func clearTextEditing() {
        selectedTextID = nil
        textStylePreview = nil
        cancelTextDraft()
    }

    func deleteSelectedText() {
        guard canSelectText, let id = selectedTextID, selectedText != nil, !isDrawing else { return }
        finishTextStyle()
        if commit(.text(id: id, annotation: nil)) != nil { selectedTextID = nil }
    }

    func textPatch(_ patch: RenderedImage, movedTo origin: CGPoint) -> RenderedImage {
        guard let bounds = frame?.bounds, let originalBounds else { return patch }
        func clamp(_ position: CGFloat, size: CGFloat, min: CGFloat, max: CGFloat,
                   originalMin: CGFloat, originalMax: CGFloat) -> CGFloat {
            let fits = size <= max - min
            let lower = Swift.max(originalMin, fits ? min : min - size + 1)
            let upper = Swift.min(originalMax - size, fits ? max - size : max - 1)
            return Swift.min(upper, Swift.max(lower, position.rounded()))
        }
        let size = patch.bounds.size
        let point = CGPoint(
            x: clamp(origin.x, size: size.width, min: bounds.minX, max: bounds.maxX,
                originalMin: originalBounds.minX, originalMax: originalBounds.maxX),
            y: clamp(origin.y, size: size.height, min: bounds.minY, max: bounds.maxY,
                originalMin: originalBounds.minY, originalMax: originalBounds.maxY))
        return RenderedImage(image: patch.image, bounds: CGRect(origin: point, size: size))
    }

    func moveText(_ id: UUID, to patch: RenderedImage) {
        guard var annotation = textOverlay.annotations[id], annotation.patch.bounds != patch.bounds else { return }
        annotation.patch = patch
        commit(.text(id: id, annotation: annotation))
    }

    @discardableResult
    func commit(_ operation: EditOperation) -> Int? {
        guard isEditing, source != nil, !isBusy else { return nil }
        history.append(operation); pendingCrop = nil
        savedFeedback = false
        editRevision += 1
        window?.isDocumentEdited = isDirty
        if case .mosaic = operation {
            // The canvas already displays this exact patch; do not regenerate it on mouse-up.
            return editRevision
        }
        if case .crop = operation, let frame,
           let cropped = try? ImageRenderer.render(source: frame.image, originalBounds: frame.bounds, operations: [operation]) {
            self.frame = cropped
        }
        renderPreview(dimension: requestedDimension)
        return editRevision
    }

    func applyCrop() {
        guard !isBusy, !isDrawing, pendingMosaicCount == 0, let rect = pendingCrop, rect.width >= 1, rect.height >= 1 else { return }
        commit(.crop(rect.integral))
        chooseTool(.hand)
    }

    func cancelCrop() {
        guard !isBusy else { return }
        pendingCrop = nil; chooseTool(.hand)
    }

    func undo() {
        guard canUndo else { return }
        finishTextStyle()
        cancelGestureID = UUID(); pendingCrop = nil; history.undo()
        savedFeedback = false
        editRevision += 1
        if selectedText == nil { selectedTextID = nil }
        window?.isDocumentEdited = isDirty; renderPreview(dimension: requestedDimension)
    }

    func redo() {
        guard canRedo else { return }
        finishTextStyle()
        guard canRedo else { return }
        cancelGestureID = UUID(); pendingCrop = nil; history.redo()
        savedFeedback = false
        editRevision += 1
        if selectedText == nil { selectedTextID = nil }
        window?.isDocumentEdited = isDirty; renderPreview(dimension: requestedDimension)
    }

    func restoreEdits() {
        guard canRestore else { return }
        let alert = NSAlert()
        alert.messageText = "舍弃未保存的修改？"
        alert.informativeText = isUntitled ? "画布将恢复到新建时的白色背景，尺寸保持不变。放弃的修改无法撤销。"
            : "图片将恢复到最近一次保存的状态。已保存的内容会保留，放弃的修改无法撤销。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.addButton(withTitle: "舍弃修改").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        canvas?.cancelPendingMosaics()
        history.restoreSaved(); editRevision += 1
        clearTextEditing()
        savedFeedback = false
        pendingCrop = nil
        chooseTool(.hand)
        window?.isDocumentEdited = isDirty
        renderPreview(dimension: requestedDimension)
    }

    func setZoom(actualSize: Bool) {
        viewportCommand = (UUID(), actualSize); revealControls()
    }

    func updateZoom(scale: CGFloat, backingScale: CGFloat) {
        let percentage = Double(scale * backingScale * 100)
        if abs(zoomPercentage - percentage) > 0.001 { zoomPercentage = percentage }
        guard let originalBounds, let frame else { return }
        let originalMax = max(originalBounds.width, originalBounds.height)
        let wanted = min(Int(originalMax), max(2048, Int(ceil(originalMax * min(1, scale * backingScale)))))
        let currentDimension = Int(CGFloat(max(frame.image.width, frame.image.height)) * originalMax / max(frame.bounds.width, frame.bounds.height))
        guard wanted > max(requestedDimension, currentDimension) + 64 else { return }
        requestedDimension = wanted
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            renderPreview(dimension: wanted)
        }
    }

    private func renderPreview(dimension: Int) {
        guard let originalBounds else { return }
        renderTask?.cancel()
        let base = source, url = currentURL, operations = history.operations, token = generation, revision = editRevision
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image: CGImage
            if let base { image = base }
            else if let url { image = try ImageCodec.decode(url, maxDimension: dimension) }
            else { throw PicGlideError.invalidImage }
            return try ImageRenderer.render(source: image, originalBounds: originalBounds,
                                             operations: operations, maxDimension: dimension, includeText: false)
        }
        renderTask = task
        Task { [weak self] in
            do {
                let rendered = try await task.value
                guard let self, generation == token, revision >= frameRevision,
                      history.operations.starts(with: operations), !task.isCancelled else { return }
                frame = rendered; frameRevision = revision
            } catch is CancellationError {} catch {
                guard let self, generation == token, !task.isCancelled else { return }
                showError(error)
            }
        }
    }

    func makeMosaicPreview(blockSize: Double) async throws -> RenderedImage {
        guard let source, let originalBounds else { throw PicGlideError.invalidImage }
        let operations = history.operations
        let task = Task.detached(priority: .userInitiated) {
            let frame = try ImageRenderer.render(source: source, originalBounds: originalBounds,
                                                 operations: operations, maxDimension: 2048, includeText: false)
            try Task.checkCancellation()
            return try RenderedImage(image: ImageRenderer.mosaicImage(frame, blockSize: blockSize), bounds: frame.bounds)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func save(asCopy: Bool = false, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isBusy, frame != nil, originalBounds != nil else { completion?(false); return }
        let url = currentURL
        guard pendingCrop == nil && !isDrawing && pendingMosaicCount == 0 else {
            let alert = NSAlert()
            alert.messageText = pendingMosaicCount > 0 ? "正在处理马赛克" : pendingCrop != nil ? "先确认裁剪" : "先结束当前绘制"
            alert.informativeText = pendingMosaicCount > 0 ? "处理完成后即可保存，或按 Esc 取消未完成的笔迹。" : pendingCrop != nil ? "点击“裁剪”完成操作，或取消裁剪后再保存。" : "松开鼠标完成绘制，或按 Esc 取消后再保存。"
            alert.addButton(withTitle: "好")
            alert.runModal(); completion?(false); return
        }
        guard finishTextDraft() else { completion?(false); return }
        if !asCopy && multiFrame {
            showError(PicGlideError.multiFrame)
            save(asCopy: true, completion: completion); return
        }
        if asCopy || saveFormat == nil || url == nil {
            let panel = NSSavePanel()
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 28), pullsDown: true)
            popup.addItem(withTitle: "保存格式")
            popup.addItems(withTitles: ImageFormat.exportFormats.map(\.title))
            popup.item(at: 0)?.title = ImageFormat.png.title
            popup.selectItem(at: 1)
            popup.item(at: 1)?.state = .on
            popup.preferredEdge = .minY
            popup.setAccessibilityLabel("保存格式")
            let formatAction = SaveFormatAction(panel: panel)
            popup.target = formatAction; popup.action = #selector(SaveFormatAction.selectFormat(_:))
            let label = NSTextField(labelWithString: "格式：")
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let accessory = NSStackView(views: [label, popup])
            accessory.orientation = .horizontal; accessory.spacing = 10
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 40, bottom: 8, right: 20)
            panel.accessoryView = accessory
            panel.allowedContentTypes = [.png]
            panel.allowsOtherFileTypes = false
            panel.nameFieldStringValue = url.map { $0.deletingPathExtension().lastPathComponent + "-edited.png" } ?? "未命名.png"
            if let url { panel.directoryURL = url.deletingLastPathComponent() }
            isShowingPanel = true
            let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, formatAction] response in
                guard let self else { completion?(false); return }
                isShowingPanel = false; revealControls()
                withExtendedLifetime(formatAction) {}
                guard response == .OK, let selected = panel.url else { completion?(false); return }
                let format = ImageFormat.exportFormats[popup.indexOfSelectedItem - 1]
                let destination = selected.deletingPathExtension().appendingPathExtension(format.fileExtension)
                    .standardizedFileURL.resolvingSymlinksInPath()
                // The save panel must confirm the actual path, including its extension.
                if destination != selected, FileManager.default.fileExists(atPath: destination.path) {
                    let alert = NSAlert(); alert.messageText = "替换现有文件？"
                    alert.informativeText = destination.lastPathComponent
                    alert.addButton(withTitle: "替换"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { completion?(false); return }
                }
                writeImage(to: destination, format: format, completion: completion)
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
            else { panel.begin(completionHandler: finish) }
            return
        }
        guard let url else { completion?(false); return }
        writeImage(to: url, format: saveFormat ?? .png, completion: completion)
    }

    private func writeImage(to destination: URL, format: ImageFormat, completion: (@MainActor (Bool) -> Void)?) {
        guard !isBusy, canSaveCopy, let originalBounds else { completion?(false); return }
        let url = currentURL
        if destination == url && multiFrame {
            showError(PicGlideError.multiFrame); completion?(false); return
        }
        let expected = destination == url ? fingerprint : nil
        let base = source, operations = history.operations, token = generation
        let target = destination, selectedFormat = format
        isSaving = true; revealControls()
        savedFeedbackTask?.cancel(); savedFeedback = false
        Task { [weak self, loader] in
            do {
                let (savedFingerprint, original) = try await Task.detached(priority: .userInitiated) {
                    let original: CGImage
                    if let base { original = base }
                    else if let url { original = try ImageCodec.decode(url,
                        maxDimension: Int(max(originalBounds.width, originalBounds.height))) }
                    else { throw PicGlideError.invalidImage }
                    let rendered = try ImageRenderer.render(source: original, originalBounds: originalBounds, operations: operations)
                    let fingerprint = try ImageFiles.save(image: rendered.image, format: selectedFormat, to: target, expected: expected)
                    return (fingerprint, original)
                }.value
                guard let self, generation == token else { completion?(false); return }
                source = original; currentURL = target; fingerprint = savedFingerprint
                saveFormat = selectedFormat; multiFrame = false
                history.markSaved(); isSaving = false
                savedFeedback = true
                savedFeedbackTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.savedFeedback = false
                }
                window?.isDocumentEdited = false
                window?.title = target.lastPathComponent + " — PicGlide"
                if target.deletingLastPathComponent() != url?.deletingLastPathComponent() {
                    files = (try? await Task.detached {
                        try ImageFiles.images(in: target.deletingLastPathComponent())
                    }.value) ?? [target]
                }
                if !files.contains(target) {
                    files.append(target)
                    files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }
                await loader.invalidate(target)
                revealControls(); completion?(true)
            } catch {
                guard let self, generation == token else { completion?(false); return }
                isSaving = false; showError(error); completion?(false)
            }
        }
    }

    func confirmLeaving(_ action: @escaping @MainActor () -> Void) {
        guard !isBusy, pendingMosaicCount == 0 else { NSSound.beep(); return }
        guard needsLeaveConfirmation else { action(); return }
        let alert = NSAlert()
        if pendingCrop != nil {
            alert.messageText = "裁剪尚未确认"
            alert.informativeText = "继续编辑可完成或取消裁剪。舍弃后将放弃当前图片的全部未保存修改，包括裁剪选区；文件不会被保存。"
            alert.addButton(withTitle: "继续编辑").keyEquivalent = "\r"
            alert.addButton(withTitle: "舍弃修改并继续").hasDestructiveAction = true
            if alert.runModal() == .alertSecondButtonReturn { action() }
            return
        }
        alert.messageText = isUntitled ? "保存这个画布？" : "保存对图片的修改？"
        alert.informativeText = documentName
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "不保存"); alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save { success in if success { action() } }
        case .alertSecondButtonReturn: action()
        default: break
        }
    }

    func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "未能完成操作"; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private extension EditOperation {
    var title: String {
        switch self { case .crop: "裁剪"; case .mosaic: "马赛克"; case .rectangle: "画框"; case .pencil: "铅笔"
        case .fill: "涂色"; case .text(_, let annotation): annotation == nil ? "删除文字" : "文字" }
    }
}

@MainActor
private final class SaveFormatAction: NSObject {
    weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }
    @objc func selectFormat(_ popup: NSPopUpButton) {
        let index = popup.indexOfSelectedItem - 1
        guard ImageFormat.exportFormats.indices.contains(index) else { return }
        let format = ImageFormat.exportFormats[index]
        popup.item(at: 0)?.title = format.title
        for (offset, item) in popup.itemArray.dropFirst().enumerated() {
            item.state = offset == index ? .on : .off
        }
        panel?.allowedContentTypes = [UTType(format.typeIdentifier)!]
        if let name = panel?.nameFieldStringValue {
            panel?.nameFieldStringValue = (name as NSString).deletingPathExtension + "." + format.fileExtension
        }
    }
}
