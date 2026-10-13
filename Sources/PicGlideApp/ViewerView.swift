import SwiftUI

struct ViewerView: View {
    @Bindable var model: ViewerModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canvasColor: Color {
        colorScheme == .dark ? Color(white: 0.085) : Color(white: 0.91)
    }

    var body: some View {
        ZStack {
            canvasColor
            ImageCanvas(model: model)
                .padding(.top, 40)
            if model.frame != nil, model.files.count > 1, !model.isEditing, !model.isBusy {
                if model.navigationHover != 0 {
                    navigationButton(model.navigationHover)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: model.navigationHover < 0 ? .leading : .trailing)
                        .padding(.horizontal, 16).padding(.top, 40)
                        .transition(.opacity)
                }
            }
            if model.frame == nil && !model.isLoading { emptyView }
            if model.isLoading || model.isPreparingEdit || model.isSaving {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.isSaving ? "正在保存" : model.isPreparingEdit ? "正在准备编辑" : "正在打开图片")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            if model.frame != nil {
                VStack {
                    header
                    Spacer(minLength: 0)
                    if model.controlsVisible {
                        controls
                            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.controlsVisible)
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
        .disabled(!enabled || model.isLoading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .accessibilityLabel(title)
    }

    private var emptyView: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 120, height: 120)
            VStack(spacing: 8) {
                Text("PicGlide").font(.system(size: 28, weight: .medium, design: .rounded))
                Text(model.loadingError ?? "拖入图片，开始浏览")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 390)
            }
            Button(action: model.openPanel) {
                HStack(spacing: 16) {
                    Text("打开图片").fontWeight(.medium)
                    Text("⌘O").foregroundStyle(.white.opacity(0.65))
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            .buttonStyle(ClickableButtonStyle(prominent: true, help: "打开图片（⌘O）"))
            Text("拖动移动  ·  滚轮缩放  ·  方向键切换")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 72)
            Spacer(minLength: 0)
            Text(model.currentURL?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if model.isDirty { Circle().fill(.orange).frame(width: 5, height: 5).help("未保存") }
            Text(model.dimensions).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Spacer().frame(width: 72)
        }
        .frame(height: 40)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
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
                        .buttonStyle(ClickableButtonStyle(selected: model.tool == tool, help: toolHelp(tool)))
                        .accessibilityLabel(tool.title)
                        .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                    }
                    separator
                    iconButton("撤销", symbol: "arrow.uturn.backward", enabled: model.canUndo,
                               help: model.canUndo ? "撤销（⌘Z）" : "无法撤销", action: model.undo)
                    iconButton("重做", symbol: "arrow.uturn.forward", enabled: model.canRedo,
                               help: model.canRedo ? "重做（⇧⌘Z）" : "无法重做", action: model.redo)
                } else {
                    iconButton("上一张", symbol: "chevron.left", enabled: model.index > 0,
                               help: model.index > 0 ? "上一张（← / ↑）" : "第一张") { model.navigate(-1) }
                    Text("\(model.index + 1) / \(model.files.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 78)
                        .help("第 \(model.index + 1) 张，共 \(model.files.count) 张")
                    iconButton("下一张", symbol: "chevron.right", enabled: model.index + 1 < model.files.count,
                               help: model.index + 1 < model.files.count ? "下一张（→ / ↓）" : "最后一张") { model.navigate(1) }
                    separator
                }
                zoomMenu
                Spacer(minLength: 4)
                if model.isEditing {
                    Button(action: model.restoreEdits) {
                        Text("恢复").font(.system(size: 12, weight: .medium)).frame(width: 48, height: 32)
                    }
                    .buttonStyle(ClickableButtonStyle(help: model.restoreHelp)).disabled(!model.canRestore)
                }
                Button(action: model.toggleEditing) {
                    Text(model.isEditing ? "返回浏览" : "编辑")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(width: model.isEditing ? 76 : 48, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(help: model.isEditing ? "返回浏览（⌘E）" : "编辑（⌘E）"))
                .disabled(model.pendingMosaicCount > 0)
                Button { model.save() } label: {
                    Text("保存").font(.system(size: 12, weight: .medium)).frame(width: 52, height: 32)
                }
                .buttonStyle(ClickableButtonStyle(prominent: true, help: model.saveHelp)).disabled(!model.canSave)
                if model.isEditing {
                    Menu {
                        Button("另存为…（⇧⌘S）") { model.save(asCopy: true) }.disabled(!model.canSaveCopy)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 32, height: 32)
                    .background(CursorRegion(cursor: .pointingHand, help: model.pendingCrop == nil
                        ? "更多" : "先确认裁剪"))
                    .accessibilityLabel("更多操作").accessibilityHint("更多操作：另存为（⇧⌘S）")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if model.isEditing && model.tool != .hand && model.tool != .crop {
                Divider().opacity(0.4).padding(.horizontal, 12)
                toolOptions.frame(height: 32).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
        .frame(width: model.isEditing ? 580 : 472)
        .background(CursorRegion(cursor: .arrow, model: model))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.4)))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.1), radius: 12, y: 5)
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
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(width: 64, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 64, height: 32)
        .background(CursorRegion(cursor: .pointingHand, help: "缩放"))
        .accessibilityLabel("缩放比例").accessibilityHint("适应窗口（⌘0）／原始尺寸（⌘1）")
    }

    @ViewBuilder private var toolOptions: some View {
        switch model.tool {
        case .hand:
            EmptyView()
        case .crop:
            EmptyView()
        case .mosaic:
            HStack(spacing: 9) {
                Text("画笔大小").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.mosaicDiameter }, set: { model.mosaicDiameter = $0.rounded() }), in: 8...512)
                    .frame(width: 112).background(CursorRegion(cursor: .arrow, help: "圆形画笔直径，按图片像素计算"))
                    .accessibilityLabel("马赛克画笔直径")
                Text("\(Int(model.mosaicDiameter)) px").font(.system(size: 10, design: .monospaced)).frame(width: 44)
                Text("颗粒").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.blockSize }, set: { model.blockSize = $0.rounded() }), in: 4...64).frame(width: 112)
                    .background(CursorRegion(cursor: .arrow, help: "马赛克颗粒大小，数值越大颗粒越粗"))
                    .accessibilityLabel("马赛克颗粒大小")
                Text("\(Int(model.blockSize)) px").font(.system(size: 10, design: .monospaced)).frame(width: 42)
            }
        case .pencil, .rectangle:
            HStack(spacing: 9) {
                Text("颜色").font(.system(size: 11)).foregroundStyle(.secondary)
                ColorPicker("颜色", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 30).help("颜色")
                Text("粗细").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.lineWidth }, set: { model.lineWidth = $0.rounded() }), in: 1...64).frame(width: 94)
                    .background(CursorRegion(cursor: .arrow, help: "线条粗细，按图片像素计算")).accessibilityLabel("线条粗细")
                Text("\(Int(model.lineWidth))").font(.system(size: 10, design: .monospaced)).frame(width: 19)
                Text("透明度").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $model.opacity, in: 0.05...1).frame(width: 88)
                    .background(CursorRegion(cursor: .arrow, help: "线条透明度")).accessibilityLabel("线条透明度")
                Text("\(Int(model.opacity * 100))%")
                    .font(.system(size: 10, design: .monospaced)).frame(width: 33)
            }
        }
    }

    private var separator: some View { Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 19).padding(.horizontal, 2) }

    private func toolHelp(_ tool: EditTool) -> String { tool.title }

    private func iconButton(_ title: String, symbol: String, enabled: Bool = true, help: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32) }
            .buttonStyle(ClickableButtonStyle(help: help ?? title)).disabled(!enabled)
            .accessibilityLabel(title)
    }
}

struct CropControls: View {
    @Bindable var model: ViewerModel

    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.cancelCrop) {
                Text("取消").font(.system(size: 12)).frame(width: 56, height: 32)
            }
            .buttonStyle(ClickableButtonStyle(help: "取消（Esc）"))
            .keyboardShortcut(.cancelAction)
            Button(action: model.applyCrop) {
                Text("应用 ↵").font(.system(size: 12, weight: .medium)).frame(width: 64, height: 32)
            }
            .buttonStyle(ClickableButtonStyle(prominent: true, help: "应用（Enter）"))
            .keyboardShortcut(.defaultAction)
        }
        .padding(8).frame(width: 140, height: 48)
        .background(CursorRegion(cursor: .arrow))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .disabled(model.isBusy || model.isDrawing)
    }
}
