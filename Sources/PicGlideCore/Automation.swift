import Foundation
import CoreGraphics

public struct AutomationError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let operationIndex: Int?
    public init(_ code: String, _ message: String, operationIndex: Int? = nil) {
        self.code = code; self.message = message; self.operationIndex = operationIndex
    }
    public var errorDescription: String? { message }
}

public struct AutomationRequest: Sendable {
    public let input: URL
    public let output: URL
    public let operations: [AutomationOperation]

    public init(data: Data) throws {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw AutomationError("invalid_request", "请求必须是合法 JSON。") }
        guard let object = value as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "input", "output", "operations"]),
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let input = object["input"] as? String, input.hasPrefix("/"), !input.contains("\0"),
              let output = object["output"] as? String, output.hasPrefix("/"), !output.contains("\0"),
              let operations = object["operations"] as? [[String: Any]] else {
            throw AutomationError("invalid_request", "需要 schemaVersion: 1、绝对路径 input/output 和 operations 数组；不接受未知字段。")
        }
        self.input = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: output).standardizedFileURL
        // Resolve the parent only: resolving the final symlink would bypass create-new protection.
        self.output = target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent)
        self.operations = try operations.enumerated().map { index, value in
            do { return try AutomationOperation(object: value) }
            catch let error as AutomationError { throw AutomationError(error.code, error.message, operationIndex: index) }
        }
    }

    public var format: ImageFormat {
        get throws {
            switch output.pathExtension.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "webp": return .webp
            default: throw AutomationError("unsupported_output", "输出文件后缀必须为 png、jpg、jpeg 或 webp。")
            }
        }
    }

    @discardableResult
    public func execute() throws -> RenderedImage {
        let format = try format
        guard ImageFormat.supports(input) else { throw AutomationError("unsupported_input", "不支持此输入格式。") }
        guard input != output else { throw AutomationError("output_exists", "输出必须是新文件，不能覆盖源图。") }
        let metadata = try ImageMetadata.read(input)
        let source = try ImageCodec.decode(input, maxDimension: Int(max(metadata.pixelSize.width, metadata.pixelSize.height)))
        guard try FileFingerprint.read(input) == metadata.fingerprint else { throw PicGlideError.externallyChanged }
        var frame = RenderedImage(image: source, bounds: metadata.bounds)
        for (index, operation) in operations.enumerated() {
            do { frame = try operation.apply(to: frame) }
            catch let error as AutomationError { throw AutomationError(error.code, error.message, operationIndex: index) }
        }
        try ImageFiles.save(image: frame.image, format: format, to: output, policy: .createNew)
        return frame
    }
}

public struct AutomationOperation: Sendable {
    private let type: String
    private let rect: CGRect
    private let points: [CGPoint]
    private let ink: Ink
    private let width: Double
    private let diameter: Double
    private let blockSize: Double

    fileprivate init(object: [String: Any]) throws {
        guard let type = object["type"] as? String else { throw AutomationError("invalid_operation", "操作缺少 type。") }
        let style = Set(["color", "lineWidth", "opacity"])
        let coordinates = Set(["x", "y", "width", "height"])
        let allowed: Set<String>
        switch type {
        case "crop": allowed = coordinates
        case "rectangle": allowed = coordinates.union(style)
        case "pencil": allowed = style.union(["points"])
        case "mosaic": allowed = ["points", "diameter", "blockSize"]
        default: throw AutomationError("invalid_operation", "不支持的操作：\(type)。")
        }
        guard Set(object.keys).isSubset(of: allowed.union(["type"])) else {
            throw AutomationError("invalid_operation", "操作包含未知字段。")
        }
        func number(_ key: String, default fallback: Double? = nil, in range: ClosedRange<Double>? = nil) throws -> Double {
            if object[key] == nil, let fallback { return fallback }
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, range?.contains(value.doubleValue) != false else {
                throw AutomationError("invalid_operation", "\(key) 缺失或超出允许范围。")
            }
            return value.doubleValue
        }
        self.type = type
        if type == "crop" || type == "rectangle" {
            let x = try number("x"), y = try number("y"), width = try number("width"), height = try number("height")
            guard width >= 1, height >= 1,
                  type != "crop" || [x, y, width, height].allSatisfy({ $0.rounded() == $0 }) else {
                throw AutomationError("invalid_operation", "区域至少为 1×1px；裁剪坐标与尺寸必须为整数。")
            }
            rect = CGRect(x: x, y: y, width: width, height: height)
            points = []
        } else {
            guard let values = object["points"] as? [[String: Any]], !values.isEmpty else {
                throw AutomationError("invalid_operation", "points 至少包含一个坐标。")
            }
            points = try values.map { value in
                guard Set(value.keys) == Set(["x", "y"]), let x = value["x"] as? NSNumber,
                      let y = value["y"] as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(),
                      CFGetTypeID(y) != CFBooleanGetTypeID(), x.doubleValue.isFinite, y.doubleValue.isFinite else {
                    throw AutomationError("invalid_operation", "每个点必须含有限数值 x、y。")
                }
                return CGPoint(x: x.doubleValue, y: y.doubleValue)
            }
            rect = .zero
        }
        let color = object["color"] as? String ?? "#3DA3FF"
        guard object["color"] == nil || object["color"] is String,
              color.count == 7, color.first == "#", color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let rgb = UInt32(color.dropFirst(), radix: 16) else {
            throw AutomationError("invalid_operation", "color 必须为 #RRGGBB。")
        }
        let opacity = try number("opacity", default: 1, in: 0.05...1)
        ink = Ink(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255, alpha: opacity)
        width = try number("lineWidth", default: 6, in: 1...64)
        diameter = try number("diameter", default: 20, in: 8...512)
        blockSize = try number("blockSize", default: 24, in: 4...64)
    }

    public func apply(to frame: RenderedImage) throws -> RenderedImage {
        let localBounds = CGRect(origin: .zero, size: frame.bounds.size)
        guard (rect == .zero || localBounds.contains(rect)),
              points.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x < localBounds.width && $0.y < localBounds.height }) else {
            throw AutomationError("out_of_bounds", "操作坐标超出当前步骤图片的范围。")
        }
        let translated = points.map { CGPoint(x: $0.x + frame.bounds.minX, y: $0.y + frame.bounds.minY) }
        let positioned = rect.offsetBy(dx: frame.bounds.minX, dy: frame.bounds.minY)
        let operation: EditOperation
        switch type {
        case "crop": operation = .crop(positioned)
        case "rectangle": operation = .rectangle(positioned, ink: ink, width: width)
        case "pencil": operation = .pencil(translated, ink: ink, width: width)
        default:
            let colors = try RenderedImage(image: ImageRenderer.mosaicImage(frame, blockSize: blockSize), bounds: frame.bounds)
            let patch = try ImageRenderer.mosaicPatch(from: colors, points: translated, diameter: diameter)
            operation = .mosaic(translated, diameter: diameter, blockSize: blockSize, patch: patch)
        }
        return try ImageRenderer.render(source: frame.image, originalBounds: frame.bounds, operations: [operation])
    }
}
