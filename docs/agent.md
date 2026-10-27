# Agent 调用

PicGlide 提供本地命令行，用于读取图片信息、按坐标处理图片并生成新文件。无须启动后台服务、配置 MCP 或调用模型。默认不打开窗口，也不改变当前窗口的编辑状态。

需要已安装支持此接口的 PicGlide。入口为 `/Applications/PicGlide.app/Contents/MacOS/PicGlide`；无需安装全局命令。

## 发现能力与检查图片

```sh
picglide_bin='/Applications/PicGlide.app/Contents/MacOS/PicGlide'
"$picglide_bin" --cli capabilities
"$picglide_bin" --cli inspect '/绝对路径/原图.png'
"$picglide_bin" --cli --help
```

`capabilities` 返回接口版本、支持的操作、字段、参数默认值和范围。`inspect` 返回方向修正后的像素宽高、格式及帧数。先检查尺寸，再计算编辑坐标。输入支持 JPG、PNG、WebP、HEIC/HEIF、BMP、TIFF 和 GIF。

## 处理图片

将以下内容保存为 JSON 请求文件；也可通过标准输入传入。路径必须为绝对路径，输出目录须已存在。示例假定输入至少为 1000×800 像素。

```json
{
  "schemaVersion": 1,
  "input": "/绝对路径/原图.png",
  "output": "/绝对路径/处理结果.png",
  "operations": [
    { "type": "crop", "x": 100, "y": 80, "width": 800, "height": 600 },
    { "type": "rectangle", "x": 40, "y": 40, "width": 300, "height": 150, "color": "#3DA3FF", "lineWidth": 6 },
    { "type": "pencil", "points": [{ "x": 100, "y": 300 }, { "x": 700, "y": 350 }], "opacity": 0.8 },
    { "type": "mosaic", "points": [{ "x": 100, "y": 480 }, { "x": 600, "y": 480 }], "diameter": 20, "blockSize": 24 }
  ]
}
```

```sh
"$picglide_bin" --cli edit --request '/绝对路径/request.json'
"$picglide_bin" --cli edit --request - < '/绝对路径/request.json'
# 按需请求本机 PicGlide 打开生成结果
"$picglide_bin" --cli edit --request '/绝对路径/另一个请求.json' --open
```

每次调用独立执行整个请求。重复调用必须选择新的输出路径；没有覆盖、追加写入或隐式丢弃修改的选项。

### 坐标与参数

坐标均以**当前步骤图片左上角**为原点，使用方向修正后的图像像素；向右为 x 正方向，向下为 y 正方向。操作依次执行，裁剪后坐标原点重置。例如先从 `(100,80)` 裁剪，再于 `(40,40)` 画框，画框位于原图的 `(140,120)`。

| 操作 | 必填字段 | 可选字段与默认值 |
| --- | --- | --- |
| `crop` | `x`、`y`、`width`、`height` | 无；坐标和尺寸为整数，尺寸至少 1×1px |
| `rectangle` | `x`、`y`、`width`、`height` | `color: "#3DA3FF"`、`lineWidth: 6`、`opacity: 1` |
| `pencil` | `points: [{"x":0,"y":0}]` | 与画框相同的颜色、线宽和透明度 |
| `mosaic` | `points: [{"x":0,"y":0}]` | `diameter: 20`、`blockSize: 24` |

圆形马赛克和铅笔均支持单点及连续路径。区域与路径点须在当前步骤图片内，笔刷超出图片边缘的部分被裁切。数值须有限，禁止布尔值代替数值；未知字段和操作会报错。

- 马赛克直径：8–512px；颗粒：4–64px。
- 线宽：1–64px；透明度：0.05–1；颜色：`#RRGGBB`。
- 空 `operations` 数组可用于格式转换。
- 输出后缀支持 `.png`、`.jpg`、`.jpeg`、`.webp`。JPEG 质量为 95%，透明区域使用白底；WebP 无损并保留透明度。
- GIF 等多帧输入按现有首帧策略处理，返回 `first_frame_only` 警告，输出静态图片。重新编码不保证保留原始元数据。

## 返回值与错误

除帮助文本外，标准输出始终是单个 JSON 对象；诊断信息写入标准错误。成功示例：

```json
{"schemaVersion":1,"ok":true,"result":{"output":"/绝对路径/处理结果.png","pixelWidth":800,"pixelHeight":600,"format":"png","warnings":[]}}
```

失败示例，`operationIndex` 从 0 开始，仅在能定位到具体操作时返回：

```json
{"schemaVersion":1,"ok":false,"error":{"code":"out_of_bounds","message":"操作坐标超出当前步骤图片的范围。","operationIndex":1}}
```

| 退出码 | 含义 |
| --- | --- |
| `0` | 处理或查询成功 |
| `2` | 请求、命令参数、操作、坐标或输出格式无效 |
| `1` | 文件、编码或其他处理失败 |

稳定错误码包括 `invalid_arguments`、`invalid_request`、`invalid_operation`、`out_of_bounds`、`unsupported_input`、`unsupported_output`、`output_exists`；其他处理失败返回 `processing_failed` 并提供具体说明。

### 文件保护与结果展示

只创建新文件，拒绝已有目标、源图本身及已有符号链接。先在目标目录生成临时文件并完成解码验证，再以排他方式提交，避免并发覆盖。文件系统不支持排他提交时返回失败，不降级为覆盖。失败时清理临时文件，保留源图及已有目标。

`--open` 成功发送打开请求时返回 `presentation: "requested"`，表示已请求展示，并不保证图片已在窗口中显示。当前窗口存在未保存修改或待确认裁剪时，仍由用户确认如何继续。打开请求失败会附加 `open_failed` 警告，已生成文件仍然保留且处理成功。

此接口不提供当前窗口的状态查询、交互控制、自动选区识别或内容理解；坐标由调用者根据图片确定。
