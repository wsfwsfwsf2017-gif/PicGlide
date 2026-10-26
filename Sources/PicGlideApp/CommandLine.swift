import Foundation
import AppKit
import PicGlideCore
import Darwin

@MainActor
enum AgentCommandLine {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            let result: [String: Any]
            switch arguments.first {
            case "capabilities" where arguments.count == 1:
                result = ["commands": ["capabilities", "inspect <absolute-path>", "edit --request <path|-> [--open]"],
                    "coordinates": "top-left pixels of the current step; crop resets the origin",
                    "requestFields": ["schemaVersion": 1, "input": "absolute path", "output": "new absolute path", "operations": "ordered array"],
                    "operations": [
                        "crop": ["required": ["x", "y", "width", "height"], "integerPixels": true],
                        "rectangle": ["required": ["x", "y", "width", "height"], "optional": ["color", "lineWidth", "opacity"]],
                        "pencil": ["required": ["points"], "optional": ["color", "lineWidth", "opacity"]],
                        "mosaic": ["required": ["points"], "optional": ["diameter", "blockSize"]]],
                    "points": "nonempty [{x:number,y:number}], within current image",
                    "defaults": ["diameter": 20, "blockSize": 24, "lineWidth": 6, "color": "#3DA3FF", "opacity": 1],
                    "ranges": ["diameter": [8, 512], "blockSize": [4, 64], "lineWidth": [1, 64], "opacity": [0.05, 1]],
                    "inputFormats": ImageFormat.extensions.sorted(),
                    "outputFormats": ["png", "jpg", "jpeg", "webp"], "overwrite": false,
                    "multiFrame": "first frame only; warning returned", "version": appVersion,
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                    "documentation": Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Agent使用说明.md").path]
            case "inspect" where arguments.count == 2:
                guard arguments[1].hasPrefix("/"), !arguments[1].contains("\0") else {
                    throw AutomationError("invalid_arguments", "图片路径必须为绝对路径。")
                }
                result = try information(URL(fileURLWithPath: arguments[1]))
            case "edit":
                guard arguments.count == 3 || arguments.count == 4,
                      arguments[1] == "--request", arguments.count == 3 || arguments[3] == "--open" else {
                    throw AutomationError("invalid_arguments", "使用 edit --request <JSON文件或-> [--open]。")
                }
                let data = try arguments[2] == "-" ? FileHandle.standardInput.readToEnd() ?? Data()
                    : Data(contentsOf: URL(fileURLWithPath: arguments[2]))
                let request = try AutomationRequest(data: data)
                guard ImageFormat.supports(request.input) else { throw AutomationError("unsupported_input", "不支持此输入格式。") }
                _ = try request.format
                let input = try ImageMetadata.read(request.input)
                let image = try request.execute()
                var value: [String: Any] = ["output": request.output.path, "pixelWidth": image.image.width,
                    "pixelHeight": image.image.height, "format": try request.format.rawValue]
                var warnings = input.frameCount > 1 ? ["first_frame_only"] : []
                if arguments.last == "--open" {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-a", "/Applications/PicGlide.app", request.output.path]
                    process.standardOutput = FileHandle.standardError
                    process.standardError = FileHandle.standardError
                    do {
                        try process.run(); process.waitUntilExit()
                        if process.terminationStatus == 0 { value["presentation"] = "requested" }
                        else { warnings.append("open_failed") }
                    } catch { warnings.append("open_failed") }
                }
                value["warnings"] = warnings; result = value
            case "--help", "help":
                print("""
                PicGlide Agent CLI
                  --cli capabilities
                  --cli inspect /absolute/image.png
                  --cli edit --request /path/request.json [--open]
                  --cli edit --request - < request.json
                JSON schemaVersion: 1. Only new PNG/JPEG/WebP files are created.
                Coordinates: top-left pixels of each step; crop resets the origin.
                Full guide: Contents/Resources/Agent使用说明.md
                """)
                return 0
            default: throw AutomationError("invalid_arguments", "使用 --cli capabilities 或 --cli --help 查看调用方式。")
            }
            write(["schemaVersion": 1, "ok": true, "result": result]); return 0
        } catch {
            let automation = error as? AutomationError
            var value: [String: Any] = ["code": automation?.code ?? "processing_failed", "message": error.localizedDescription]
            if let index = automation?.operationIndex { value["operationIndex"] = index }
            write(["schemaVersion": 1, "ok": false, "error": value])
            return ["invalid_request", "invalid_arguments", "invalid_operation", "out_of_bounds", "unsupported_input", "unsupported_output"].contains(automation?.code ?? "") ? 2 : 1
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static func information(_ url: URL) throws -> [String: Any] {
        guard ImageFormat.supports(url) else { throw AutomationError("unsupported_input", "不支持此输入格式。") }
        let metadata = try ImageMetadata.read(url)
        return ["path": url.standardizedFileURL.resolvingSymlinksInPath().path,
                "pixelWidth": Int(metadata.pixelSize.width), "pixelHeight": Int(metadata.pixelSize.height),
                "format": ImageFormat.from(type: metadata.typeIdentifier)?.rawValue ?? metadata.typeIdentifier,
                "frameCount": metadata.frameCount, "coordinateOrigin": "top-left",
                "warnings": metadata.frameCount > 1 ? ["first_frame_only"] : []]
    }

    private static func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
