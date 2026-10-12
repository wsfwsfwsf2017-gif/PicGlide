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
    }

    private var emptyView: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(.thinMaterial).frame(width: 104, height: 104)
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.16)))
                Image(systemName: "photo")
                    .font(.system(size: 43, weight: .ultraLight)).foregroundStyle(.blue)
            }
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
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(.blue, in: Capsule())
            .help("打开图片（⌘O）")
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
            if model.isDirty { Circle().fill(.orange).frame(width: 5, height: 5).help("有未保存的修改") }
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
            if model.isEditing {
                HStack(spacing: 5) {
                    ForEach(EditTool.allCases, id: \.self) { tool in
                        Button { model.chooseTool(tool) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tool.symbol).font(.system(size: 16, weight: .medium))
                                Text(tool.title).font(.system(size: 10, weight: .medium))
                            }
                            .frame(width: 52, height: 48)
                            .foregroundStyle(model.tool == tool ? Color.white : Color.primary.opacity(0.75))
                            .background(model.tool == tool ? Color.blue : .clear, in: RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
                    }
                    separator
                    iconButton("撤销", symbol: "arrow.uturn.backward", enabled: model.canUndo, action: model.undo)
                    iconButton("重做", symbol: "arrow.uturn.forward", enabled: model.canRedo, action: model.redo)
                }
                .padding(.top, 10).padding(.horizontal, 12)
                toolOptions.padding(.vertical, 11).padding(.horizontal, 16)
                Divider().opacity(0.5).padding(.horizontal, 14)
            }
            HStack(spacing: 10) {
                iconButton("上一张", symbol: "chevron.left", enabled: model.index > 0) { model.navigate(-1) }
                Text("\(model.index + 1) / \(model.files.count)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(minWidth: 54)
                iconButton("下一张", symbol: "chevron.right", enabled: model.index + 1 < model.files.count) { model.navigate(1) }
                separator
                Text("\(Int(model.zoomPercentage.rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).frame(minWidth: 43)
                iconButton("适应窗口（⌘0）", symbol: "arrow.down.right.and.arrow.up.left") { model.setZoom(actualSize: false) }
                iconButton("原始尺寸（⌘1）", symbol: "1.square") { model.setZoom(actualSize: true) }
                separator
                Button(action: model.toggleEditing) {
                    Label(model.isEditing ? "完成" : "编辑", systemImage: model.isEditing ? "checkmark" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                        .background(model.isEditing ? Color.blue.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule())
                }.buttonStyle(.plain).help("切换编辑（⌘E）")
                if model.isDirty {
                    Button { model.save() } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).frame(height: 30)
                            .foregroundStyle(.white).background(.blue, in: Capsule())
                    }.buttonStyle(.plain).help("覆盖保存（⌘S）")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45)))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 18, y: 7)
        .onHover { hover in model.toolbarHovered = hover; model.revealControls() }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var toolOptions: some View {
        switch model.tool {
        case .hand:
            Text("拖动图片 · 按住空格可临时切换拖动")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 22)
        case .crop:
            HStack(spacing: 12) {
                Text("拖出保留区域 · Esc 取消").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("应用裁剪 ↵", action: model.applyCrop)
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.pendingCrop == nil)
            }.frame(height: 22)
        case .mosaic:
            HStack(spacing: 12) {
                Text("颗粒").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $model.blockSize, in: 4...64, step: 1).frame(width: 190).accessibilityLabel("马赛克颗粒大小")
                Text("\(Int(model.blockSize)) px").font(.system(size: 10, design: .monospaced)).frame(width: 42)
            }.frame(height: 22)
        case .pencil, .rectangle:
            HStack(spacing: 9) {
                ColorPicker("颜色", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 30)
                Text("粗细").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $model.lineWidth, in: 1...64, step: 1).frame(width: 94).accessibilityLabel("线条粗细")
                Text("\(Int(model.lineWidth))").font(.system(size: 10, design: .monospaced)).frame(width: 19)
                Text("透明度").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $model.opacity, in: 0.05...1).frame(width: 88).accessibilityLabel("线条透明度")
                Text("\(Int(model.opacity * 100))%")
                    .font(.system(size: 10, design: .monospaced)).frame(width: 33)
            }.frame(height: 22)
        }
    }

    private var separator: some View { Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 19).padding(.horizontal, 2) }

    private func iconButton(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 30) }
            .buttonStyle(.plain).disabled(!enabled).foregroundStyle(enabled ? .primary : .tertiary)
            .help(title).accessibilityLabel(title)
    }
}
