import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum ImageFormat: String {
    case png, jpg, webp

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpg
        case "webp": self = .webp
        default: return nil
        }
    }

    var type: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .webp: return .webP
        }
    }
}

struct Options {
    var input: String
    var output: String
    var format: ImageFormat?
    var scale: Double?
    var width: Int?
    var height: Int?
    var quality = 75
    var hasQuality = false
    var lossless: Bool?

    init(arguments: [String]) throws {
        var input: String?
        var output: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            func value() throws -> String {
                guard index < arguments.count else {
                    throw CLIError("Missing value for \(argument)")
                }
                let result = arguments[index]
                index += 1
                return result
            }
            switch argument {
            case "--input", "-i": input = try value()
            case "--output", "-o": output = try value()
            case "--format", "-f":
                let text = try value()
                guard let parsed = ImageFormat(fileExtension: text) else {
                    throw CLIError("Unsupported output format: \(text). Use png, jpg or webp.")
                }
                format = parsed
            case "--scale":
                let text = try value()
                guard let parsed = Double(text), parsed.isFinite, parsed > 0 else {
                    throw CLIError("--scale must be a positive percentage")
                }
                scale = parsed
            case "--width", "--height":
                let text = try value()
                guard let parsed = Int(text), parsed > 0 else {
                    throw CLIError("\(argument) must be a positive pixel count")
                }
                if argument == "--width" { width = parsed } else { height = parsed }
            case "--quality", "-q":
                let text = try value()
                guard let parsed = Int(text), (0...100).contains(parsed) else {
                    throw CLIError("--quality must be an integer from 0 to 100")
                }
                quality = parsed
                hasQuality = true
            case "--lossless", "--lossy":
                let parsed = argument == "--lossless"
                guard lossless == nil || lossless == parsed else {
                    throw CLIError("--lossless and --lossy cannot be used together")
                }
                lossless = parsed
            default: throw CLIError("Unknown argument: \(argument). Use --help for usage.")
            }
        }
        guard let input, !input.isEmpty, let output, !output.isEmpty else {
            throw CLIError("Both --input and --output are required")
        }
        guard scale == nil || (width == nil && height == nil) else {
            throw CLIError("Use either --scale or --width/--height")
        }
        self.input = input
        self.output = output
    }
}

let help = """
用法：pastehub-image --input <文件> --output <文件或目录> [选项]

读取单张图片，先调整尺寸，再编码；目标文件存在时直接覆盖。

  -i, --input <路径>       输入图片文件
  -o, --output <路径>      输出文件或目录；末尾带 / 可创建目录
  -f, --format <格式>      png、jpg（或 jpeg）、webp
      --scale <百分比>     按比例缩放，例如 70 表示宽高均为原来的 70%
      --width <像素>       目标宽度；仅指定宽度时按原比例计算高度
      --height <像素>      目标高度；同时指定宽高时使用精确尺寸
  -q, --quality <0–100>    JPG / 有损 WebP 的质量，默认 75
      --lossless          WebP 无损模式，不接受 --quality
      --lossy             WebP 有损模式（默认）
  -h, --help              显示帮助
      --licenses          显示第三方许可证

输出为文件时优先按扩展名确定格式；输出为目录时默认保持输入格式，
其他输入格式默认输出 PNG。可用 --format 显式指定。
PNG 使用无损编码，不接受 --quality；JPG 使用系统编码器，透明区域填白。
WebP 支持透明度。缩放与色彩转换发生在编码前，无损指编码阶段无损。

示例：
  pastehub-image -i photo.png -o result.jpg --scale 70 --quality 85
  pastehub-image -i photo.png -o ./output/ --format webp --lossless
  pastehub-image -i photo.jpg -o photo.jpg --quality 80
"""

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func outputTarget(options: Options, input: URL, source: CGImageSource) throws -> (URL, ImageFormat) {
    let output = fileURL(options.output)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory)
    let directory = (exists && isDirectory.boolValue) || options.output.hasSuffix("/")
    if exists && !isDirectory.boolValue && directory {
        throw CLIError("Output directory is an existing file: \(output.path)")
    }
    let format: ImageFormat
    if let requested = options.format {
        format = requested
        if !directory && !output.pathExtension.isEmpty,
           ImageFormat(fileExtension: output.pathExtension) != requested {
            throw CLIError("Output extension does not match --format \(requested.rawValue)")
        }
    } else if !directory && !output.pathExtension.isEmpty {
        guard let inferred = ImageFormat(fileExtension: output.pathExtension) else {
            throw CLIError("Unsupported output extension: \(output.pathExtension)")
        }
        format = inferred
    } else {
        let sourceType = CGImageSourceGetType(source) as String?
        format = [.png, .jpg, .webp].first { $0.type.identifier == sourceType } ?? .png
    }
    guard options.lossless == nil || format == .webp else {
        throw CLIError("--lossless and --lossy apply only to WebP")
    }
    guard !options.hasQuality || (format != .png && options.lossless != true) else {
        throw CLIError("--quality applies only to JPG or lossy WebP")
    }
    if directory {
        // 同格式保留原文件名，保证输出目录与输入目录相同时能替换原图。
        let filename = ImageFormat(fileExtension: input.pathExtension) == format
            ? input.lastPathComponent
            : input.deletingPathExtension().lastPathComponent + "." + format.rawValue
        return (output.appendingPathComponent(filename), format)
    }
    return (output, format)
}

func decodedImage(from source: CGImageSource) throws -> CGImage {
    guard CGImageSourceGetCount(source) == 1 else {
        throw CLIError("Only single-frame images are supported")
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else {
        throw CLIError("Cannot read input image dimensions")
    }
    // 按完整像素尺寸解码并应用 EXIF 方向，避免使用内嵌的低分辨率缩略图。
    let propertiesForDecode: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, propertiesForDecode as CFDictionary) else {
        throw CLIError("Cannot decode input image")
    }
    return image
}

func dimensions(image: CGImage, options: Options, format: ImageFormat) throws -> (Int, Int) {
    var width = Double(image.width)
    var height = Double(image.height)
    if let scale = options.scale {
        width *= scale / 100
        height *= scale / 100
    } else if let requestedWidth = options.width, let requestedHeight = options.height {
        width = Double(requestedWidth)
        height = Double(requestedHeight)
    } else if let requestedWidth = options.width {
        height *= Double(requestedWidth) / width
        width = Double(requestedWidth)
    } else if let requestedHeight = options.height {
        width *= Double(requestedHeight) / height
        height = Double(requestedHeight)
    }
    // WebP 每边最多 16383 像素；其余格式使用系统编码器支持的常规图片尺寸。
    let limit = format == .webp ? 16_383.0 : 65_500.0
    guard width.isFinite, height.isFinite, width.rounded() <= limit, height.rounded() <= limit else {
        throw CLIError("Output dimensions exceed the \(Int(limit))-pixel limit per side for \(format.rawValue)")
    }
    return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
}

func render(image: CGImage, width: Int, height: Int, format: ImageFormat) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                      | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CLIError("Cannot allocate output image buffer")
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    if format == .jpg {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
    }
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    return context
}

func encodedData(context: CGContext, format: ImageFormat, options: Options) throws -> Data {
    if format == .webp {
        guard let buffer = context.data else { throw CLIError("Cannot read output pixels") }
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)
        // CoreGraphics 使用预乘 Alpha，libwebp 的 RGBA 入口要求非预乘像素。
        for offset in stride(from: 0, to: context.bytesPerRow * context.height, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 255 { continue }
            for channel in 0..<3 {
                pixels[offset + channel] = alpha == 0 ? 0
                    : UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size: Int
        if options.lossless == true {
            size = WebPEncodeLosslessRGBA(pixels, Int32(context.width), Int32(context.height),
                                          Int32(context.bytesPerRow), &output)
        } else {
            size = WebPEncodeRGBA(pixels, Int32(context.width), Int32(context.height),
                                  Int32(context.bytesPerRow), Float(options.quality), &output)
        }
        guard size > 0, let output else { throw CLIError("WebP encoding failed") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
    guard let image = context.makeImage() else { throw CLIError("Cannot create output image") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
        throw CLIError("Cannot create image encoder")
    }
    let properties: [CFString: Any] = format == .jpg
        ? [kCGImageDestinationLossyCompressionQuality: Double(options.quality) / 100] : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CLIError("Image encoding failed") }
    return data as Data
}

func process(options: Options) throws {
    let input = fileURL(options.input)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw CLIError("Input must be an existing file: \(input.path)")
    }
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
        throw CLIError("Unsupported or unreadable input image: \(input.path)")
    }
    let (output, format) = try outputTarget(options: options, input: input, source: source)
    let image = try decodedImage(from: source)
    let (width, height) = try dimensions(image: image, options: options, format: format)
    let context = try render(image: image, width: width, height: height, format: format)
    let data = try encodedData(context: context, format: format, options: options)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 编码成功后才原子替换目标文件，输入与输出相同时也不先删除原图。
    try data.write(to: output, options: .atomic)
    let mode = format == .png || options.lossless == true ? "lossless" : "lossy, quality \(options.quality)"
    print("Saved: \(output.path)")
    print("Size: \(image.width)x\(image.height) -> \(width)x\(height), \(format.rawValue.uppercased()), \(mode), \(data.count) bytes")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
        print(help)
    } else if arguments == ["--licenses"] {
        print(thirdPartyNotices)
    } else {
        try autoreleasepool { try process(options: Options(arguments: arguments)) }
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
