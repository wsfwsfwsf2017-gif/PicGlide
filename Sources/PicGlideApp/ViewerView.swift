import SwiftUI

struct ViewerView: View {
    @Bindable var model: ViewerModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var canvasColor: Color {
        colorScheme == .dark ? Color(white: 0.085) : Color(white: 0.91)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                canvasColor
                ImageCanvas(model: model)
                    .padding(.top, 40)
                    .padding(.bottom, model.isEditing ? model.editorPanelHeight + 20 : 0)
                if model.frame != nil, model.files.count > 1, !model.isEditing, !model.isBusy,
                   model.navigationHover != 0 {
                    navigationButton(model.navigationHover)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: model.navigationHover < 0 ? .leading : .trailing)
                        .padding(.horizontal, 16).padding(.top, 40)
                        .transition(.opacity)
                }
                if model.frame == nil && !model.isLoading { emptyView }
                if model.isLoading || model.isPreparingEdit || model.isSaving {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.isSaving ? "正在保存" : model.isPreparingEdit ? "正在准备编辑" : "正在打开图片")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                if model.frame != nil {
                    VStack(spacing: 0) {
                        header(showDimensions: geometry.size.width >= 800)
                        Spacer(minLength: 0)
                        if model.isEditing || model.controlsVisible {
                            controls
                                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.controlsVisible)
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 600, minHeight: 400)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.navigationHover)
    }

    private func navigationButton(_ direction: Int) -> some View {
        let previous = direction < 0
        let enabled = previous ? model.index > 0 : model.index + 1 < model.files.count
        let title = previous ? "上一张" : "下一张"
        return Button { model.navigate(direction) } label: {
            Image(systemName: previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 112)
                .contentShape(Rectangle())
        }
        .buttonStyle(ClickableButtonStyle(help: enabled ? "\(title)（方向键）" : previous ? "第一张" : "最后一张"))
        .disabled(!enabled || model.isLoading || !model.canNavigate)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .accessibilityLabel(title)
    }

    private var emptyView: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 120, height: 120).accessibilityHidden(true)
            Text("PicGlide").font(.system(size: 28, weight: .medium, design: .rounded))
            Text(model.loadingError ?? "拖入或打开图片")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 390)
            Button(action: model.openPanel) {
                HStack(spacing: 16) {
                    Text("打开图片").fontWeight(.medium)
                    Text("⌘O").foregroundStyle(.white.opacity(0.8))
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            .buttonStyle(ClickableButtonStyle(prominent: true, help: "打开图片（⌘O）"))
            .accessibilityIdentifier("file.open")
        }
    }

    private func header(showDimensions: Bool) -> some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 58)
            HStack(spacing: 8) {
                Text(model.currentURL?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if showDimensions {
                    Text(model.dimensions).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize()
                }
                if model.isDirty {
                    Text("未保存").foregroundStyle(.secondary).fixedSize()
                        .accessibilityIdentifier("file.unsaved")
                } else if model.savedFeedback {
                    Text("已保存").foregroundStyle(.secondary).fixedSize()
                        .accessibilityIdentifier("file.saved")
                }
            }
            .font(.system(size: 11)).frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            HStack(spacing: 6) {
                Button(action: model.toggleEditing) {
                    Text("编辑")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .frame(width: 76, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(selected: model.isEditing, help: model.editHelp))
                .disabled(!model.canToggleEditing)
                .accessibilityIdentifier("edit.toggle")
                .accessibilityAddTraits(model.isEditing ? .isSelected : [])
                .padding(.trailing, 6)
                Button(action: model.restoreEdits) {
                    Text("舍弃修改…").font(.system(size: 13, weight: .medium)).frame(width: 76, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(help: model.restoreHelp))
                .disabled(!model.canRestore).accessibilityLabel("舍弃修改").accessibilityIdentifier("file.discard")
                Button { model.save(asCopy: true) } label: {
                    Text("另存为…").font(.system(size: 13, weight: .medium)).frame(width: 76, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(help: model.canSaveCopy ? "另存为（⇧⌘S）" : model.saveHelp))
                .disabled(!model.canSaveCopy).accessibilityLabel("另存为").accessibilityIdentifier("file.saveCopy")
                Button { model.save() } label: {
                    Text("保存").font(.system(size: 13, weight: .medium)).frame(width: 52, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(prominent: model.isDirty, help: model.saveHelp))
                .disabled(!model.canSave).accessibilityLabel("保存").accessibilityIdentifier("file.save")
            }
        }
        .frame(height: 40)
        .background(CursorRegion(cursor: .arrow))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if model.isEditing {
                    ForEach(EditTool.allCases, id: \.self) { tool in
                        Button { model.chooseTool(tool) } label: {
                            Image(systemName: tool.symbol).font(.system(size: 15, weight: .medium))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(ClickableButtonStyle(selected: model.tool == tool,
                            help: model.pendingCrop != nil ? "先确认裁剪" : tool.title))
                        .disabled(!model.canChooseTool)
                        .accessibilityLabel(tool.title).accessibilityIdentifier("tool.\(tool.rawValue)")
                        .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                    }
                    separator
                    iconButton(model.undoTitle, symbol: "arrow.uturn.backward", enabled: model.canUndo,
                               help: model.pendingCrop != nil ? "先确认裁剪" : model.canUndo ? "\(model.undoTitle)（⌘Z）" : "无法撤销", action: model.undo)
                    iconButton(model.redoTitle, symbol: "arrow.uturn.forward", enabled: model.canRedo,
                               help: model.pendingCrop != nil ? "先确认裁剪" : model.canRedo ? "\(model.redoTitle)（⇧⌘Z）" : "无法重做", action: model.redo)
                    separator
                } else {
                    iconButton("上一张", symbol: "chevron.left", enabled: model.index > 0 && model.canNavigate,
                               help: model.index > 0 ? "上一张（← / ↑）" : "第一张") { model.navigate(-1) }
                    Text("\(model.index + 1) / \(model.files.count)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 78)
                        .accessibilityLabel("第 \(model.index + 1) 张，共 \(model.files.count) 张")
                    iconButton("下一张", symbol: "chevron.right", enabled: model.index + 1 < model.files.count && model.canNavigate,
                               help: model.index + 1 < model.files.count ? "下一张（→ / ↓）" : "最后一张") { model.navigate(1) }
                    separator
                }
                zoomMenu
            }
            .padding(.horizontal, 10).frame(height: 48)
            if model.hasToolOptions {
                Divider().opacity(0.4).padding(.horizontal, 12)
                toolOptions.padding(.horizontal, 14).frame(height: 43)
            }
        }
        .frame(width: model.isEditing ? (model.hasToolOptions ? 560 : 376) : 280)
        .background(CursorRegion(cursor: .arrow, model: model))
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(colorScheme == .dark ? 0.14 : 0.1)))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 10, y: 4)
        .onHover { hover in model.toolbarHovered = hover; model.revealControls() }
        .disabled(model.isBusy)
    }

    private var zoomMenu: some View {
        Menu {
            Button("适应窗口（⌘0）") { model.setZoom(actualSize: false) }
            Button("原始尺寸（⌘1）") { model.setZoom(actualSize: true) }
        } label: {
            HStack(spacing: 4) {
                Text("\(Int(model.zoomPercentage.rounded()))%")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(width: 72, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 72, height: 32)
        .background(CursorRegion(cursor: .pointingHand, help: "缩放"))
        .accessibilityLabel("缩放比例").accessibilityIdentifier("view.zoom")
    }

    @ViewBuilder private var toolOptions: some View {
        HStack(spacing: 8) {
            Text(model.tool.title).font(.system(size: 12, weight: .medium)).fixedSize()
            switch model.tool {
            case .mosaic:
                parameter("大小", value: $model.mosaicDiameter, range: 8...512, unit: "px", id: "mosaicDiameter", sliderWidth: 80)
                parameter("颗粒", value: $model.blockSize, range: 4...64, unit: "px", id: "blockSize", sliderWidth: 80)
            case .pencil, .rectangle:
                Text("颜色").foregroundStyle(.secondary).fixedSize()
                ColorPicker("颜色", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 44)
                    .accessibilityLabel("画笔颜色")
                parameter("粗细", value: $model.lineWidth, range: 1...64, unit: "px", id: "lineWidth", sliderWidth: 54)
                parameter("透明度", value: Binding(get: { (model.opacity * 100).rounded() }, set: { model.opacity = $0 / 100 }),
                          range: 5...100, unit: "%", id: "opacity", sliderWidth: 54)
            default: EmptyView()
            }
        }
        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .center)
    }

    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           unit: String, id: String, sliderWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
                .frame(width: sliderWidth).background(CursorRegion(cursor: .arrow, help: title))
                .accessibilityLabel(title)
            ParameterField(value: value, range: range, label: "\(model.tool.title)\(title)", id: id, model: model)
                .frame(width: 48, height: 24)
                .background(CursorRegion(cursor: .iBeam, help: title))
            Text(unit).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 19).padding(.horizontal, 2)
    }

    private func iconButton(_ title: String, symbol: String, enabled: Bool = true, help: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32) }
            .buttonStyle(ClickableButtonStyle(help: help ?? title)).disabled(!enabled).accessibilityLabel(title)
    }
}
struct CropControls: View {
    static let size = NSSize(width: 280, height: 48)
    @Bindable var model: ViewerModel

    var body: some View {
        HStack(spacing: 4) {
            if let crop = model.pendingCrop {
                VStack(alignment: .leading, spacing: 2) {
                    Text("待确认裁剪").font(.system(size: 11))
                    Text("\(Int(crop.integral.width)) × \(Int(crop.integral.height)) px")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel("裁剪尺寸")
                }
                .lineLimit(1).minimumScaleFactor(0.9).frame(width: 112, alignment: .leading)
            }
            Button(action: model.cancelCrop) {
                Text("取消裁剪").font(.system(size: 13)).frame(width: 72, height: 32)
            }
            .buttonStyle(ClickableButtonStyle(help: "取消裁剪（Esc）")).keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("crop.cancel")
            Button(action: model.applyCrop) {
                Text("裁剪 ↵").font(.system(size: 13, weight: .medium)).frame(width: 64, height: 32)
            }
            .buttonStyle(ClickableButtonStyle(prominent: true, help: "裁剪（Enter）")).keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("crop.apply")
        }
        .padding(8).frame(width: Self.size.width, height: Self.size.height)
        .background(CursorRegion(cursor: .arrow))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .disabled(model.isBusy || model.isDrawing)
    }
}
