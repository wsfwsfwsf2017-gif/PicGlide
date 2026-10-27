# PicGlide

<img src="Resources/AppIcon.png" width="88" alt="PicGlide 图标">

轻量的 macOS 图片浏览与标注工具，支持鼠标位置缩放、基础图片编辑和本地 Agent 调用。

[下载最新版](https://github.com/wsfwsfwsf2017-gif/PicGlide/releases/latest) · [历史版本](https://github.com/wsfwsfwsf2017-gif/PicGlide/releases) · [更新记录](CHANGELOG.md) · [Agent 文档](docs/agent.md)

![PicGlide 界面](docs/screenshot.png)

## 功能

- **浏览**：拖动平移、滚轮缩放、触控板捏合，通过方向键或边缘按钮切换同目录图片。
- **编辑**：圆形马赛克、可调整选区的裁剪、矩形标注和自由铅笔，支持撤销与重做。
- **保存**：按原格式保存，或另存为 PNG、JPEG、WebP。
- **Agent 接口**：通过本地命令行检查图片、执行编辑并生成新文件，返回 JSON。
- **原生界面**：浅色与深色外观、全屏浏览，以及闲置时自动收起的浏览工具栏。

支持读取 JPG、PNG、WebP、HEIC/HEIF、BMP、TIFF 和 GIF 首帧。

GIF 等多帧图片编辑后需另存为静态图片。覆盖保存会改写原文件；重新编码可能损失画质及部分元数据。

## 下载与安装

需要 **macOS 14 或更新版本、Apple Silicon（M 系列芯片）**。

在 [Releases](https://github.com/wsfwsfwsf2017-gif/PicGlide/releases/latest) 下载对应版本的 `.dmg`，打开后将 PicGlide 拖入 Applications；也可下载 `.zip` 并解压安装。每个版本提供 SHA-256 校验文件。

当前安装包未使用 Developer ID 签名和 Apple 公证。首次打开若被系统拦截，确认下载来源后，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。[Apple 说明](https://support.apple.com/en-gb/102445)

## 常用操作

| 操作 | 快捷键／手势 |
| --- | --- |
| 打开图片 | `⌘O`、拖入窗口或 Finder 打开方式 |
| 上一张／下一张 | `←` `↑` ／ `→` `↓` |
| 平移／缩放 | 左键拖动／滚轮或触控板捏合 |
| 适应窗口／原始尺寸 | `⌘0` ／ `⌘1` |
| 展开／收起编辑工具 | `⌘E` |
| 编辑时临时平移 | 按住空格拖动 |
| 裁剪／取消裁剪 | `↵` ／ `Esc` |
| 撤销／重做 | `⌘Z` ／ `⇧⌘Z` |
| 保存／另存为 | `⌘S` ／ `⇧⌘S` |
| 全屏 | `⌃⌘F` |

“编辑”仅展开或收起工具，不自动保存；“保存”写入当前文件，“另存为…”保存到新文件并继续操作。“舍弃修改…”经确认后恢复到最近一次保存，舍弃的修改无法撤销。

裁剪选区需确认或取消后再保存、切换工具或翻图。离开有未保存内容的图片时，会要求确认。

## Agent 调用

无需配置后台服务或模型，默认不打开窗口。支持信息查询、裁剪、马赛克、画框和铅笔操作；编辑只创建新文件，不覆盖源图或已有目标。

```sh
picglide_bin='/Applications/PicGlide.app/Contents/MacOS/PicGlide'
"$picglide_bin" --cli capabilities
"$picglide_bin" --cli inspect '/path/to/image.png'
```

将占位路径替换为实际图片路径。请求格式、坐标约定和错误码见 [Agent 使用说明](docs/agent.md)。

## 本地构建

使用 Swift 6 和 Xcode Command Line Tools，首次构建由 SwiftPM 获取依赖。

```sh
./scripts/build-app.sh
```

构建产物位于 `build/PicGlide.app`。运行测试使用 `./scripts/test.sh`，制作 DMG 和 ZIP 使用 `./scripts/package-release.sh`。

## 许可证

PicGlide 使用 [MIT 许可证](LICENSE)。WebP 编码依赖 [libwebp-Xcode / libwebp](https://github.com/SDWebImage/libwebp-Xcode)，使用 BSD-3-Clause 许可证；相关版权声明随 App 分发。
