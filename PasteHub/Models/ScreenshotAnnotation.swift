import AppKit

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, pen, line, arrow, mosaic, solid, text

    nonisolated var id: String { rawValue }
    var isBrush: Bool { self == .mosaic || self == .solid }
    var isFreehand: Bool { self == .pen || isBrush }
    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .mosaic: return "马赛克"
        case .solid: return "纯色涂抹"
        case .text: return "文字（T）"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .mosaic: return "square.grid.3x3.fill"
        case .solid: return "paintbrush.fill"
        case .text: return "t.square"
        }
    }
}

struct ScreenshotAnnotation {
    let tool: ScreenshotTool
    var color: NSColor
    let lineWidth: CGFloat
    var points: [CGPoint]
    var text = ""
    var fontSize: CGFloat = 24
    var textWidth: CGFloat = 1

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color]
    }

    // 输入框和导出共用 TextKit 排版，保持中文、换行和字形位置一致。
    func makeTextLayout() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: textAttributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return (storage, layout, container)
    }

    var textRect: CGRect {
        guard let point = points.first else { return .zero }
        let (storage, layout, container) = makeTextLayout()
        return withExtendedLifetime(storage) {
            layout.usedRect(for: container).offsetBy(dx: point.x, dy: point.y)
        }
    }

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    func draw(in context: CGContext, mosaic: CGImage, canvasSize: CGSize) {
        guard let first = points.first, let last = points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch tool {
        case .text:
            let (storage, layout, container) = makeTextLayout()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: container)
            withExtendedLifetime(storage) {
                layout.drawGlyphs(forGlyphRange: range, at: first)
            }
            NSGraphicsContext.restoreGraphicsState()
        case .rectangle:
            context.stroke(rect)
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .pen, .mosaic, .solid:
            context.addPath(brushPath)
            if tool == .mosaic {
                context.clip()
                context.interpolationQuality = .none
                ScreenshotRaster.draw(mosaic, in: CGRect(origin: .zero, size: canvasSize), context: context)
            } else {
                context.fillPath()
            }
        case .line, .arrow:
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
            if tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(12, lineWidth * 4)
                context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6),
                                        y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6),
                                           y: last.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        }
    }

    private var brushPath: CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        if points.count == 1 {
            path.addEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2,
                                      width: lineWidth, height: lineWidth))
        } else {
            let stroke = CGMutablePath()
            stroke.addLines(between: points)
            path.addPath(stroke.copy(strokingWithWidth: lineWidth, lineCap: .round,
                                     lineJoin: .round, miterLimit: 10))
        }
        return path
    }
}

// 预览与导出共用相同的绘制过程，坐标统一为左上角原点。
enum ScreenshotRaster {
    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func pixelated(_ image: CGImage, canvasSize: CGSize) -> CGImage? {
        let width = max(1, Int(canvasSize.width / 12))
        let height = max(1, Int(canvasSize.height / 12))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func export(image: CGImage, mosaic: CGImage, canvasSize: CGSize,
                       selection: CGRect, annotations: [ScreenshotAnnotation]) -> CGImage? {
        let scaleX = CGFloat(image.width) / canvasSize.width
        let scaleY = CGFloat(image.height) / canvasSize.height
        let pixels = CGRect(x: selection.minX * scaleX, y: selection.minY * scaleY,
                            width: selection.width * scaleX, height: selection.height * scaleY).integral
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -pixels.minX, y: pixels.height + pixels.minY)
        context.scaleBy(x: scaleX, y: -scaleY)
        draw(image, in: CGRect(origin: .zero, size: canvasSize), context: context)
        for annotation in annotations {
            annotation.draw(in: context, mosaic: mosaic, canvasSize: canvasSize)
        }
        return context.makeImage()
    }
}
