import AppKit
import UniformTypeIdentifiers

enum ScreenshotQualityPreset: String, CaseIterable, Identifiable {
    case high, medium, low, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        case .custom: return "自定义"
        }
    }
}

enum ScreenshotImageFormat: String, CaseIterable, Identifiable {
    case png, jpg

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var contentType: UTType { self == .png ? .png : .jpeg }
    var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(contentType.identifier) }
}

// 截图复制和保存共用的导出参数，先缩放一次，再按目标格式编码一次。
struct ScreenshotExportOptions {
    var format: ScreenshotImageFormat = .png
    var scalePercent: Int = 100
    var qualityPercent: Int = 100

    func encodedData(from image: CGImage) -> Data? {
        let output: CGImage
        if scalePercent == 100 {
            output = image
        } else {
            let width = max(1, Int((Double(image.width) * Double(scalePercent) / 100).rounded()))
            let height = max(1, Int((Double(image.height) * Double(scalePercent) / 100).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let bitmap = NSBitmapImageRep(cgImage: output)
        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpg:
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: Double(qualityPercent) / 100])
        }
    }
}
