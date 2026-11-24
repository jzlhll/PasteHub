import SwiftUI
import AppKit

@MainActor
@Observable
final class ScreenshotEditorState {
    enum TextRecognitionState: Equatable {
        case idle
        case selecting
        case recognizing
        case result
        case failed(String)
        case timedOut

        var symbol: String? {
            switch self {
            case .idle, .selecting, .recognizing, .result: return nil
            case .failed: return "exclamationmark.triangle.fill"
            case .timedOut: return "clock.badge.exclamationmark"
            }
        }

        var title: String {
            switch self {
            case .idle, .result: return String(localized: "框选识别文字")
            case .selecting: return String(localized: "在截图内框选需要识别的文字（Esc 返回）")
            case .recognizing: return String(localized: "正在提取文字")
            case .failed(let message): return message
            case .timedOut: return String(localized: "提取超时，请重试")
            }
        }

        var tint: Color {
            switch self {
            case .idle, .recognizing: return Color(nsColor: .darkGray)
            case .selecting, .result: return .blue
            case .failed: return .red
            case .timedOut: return .orange
            }
        }
    }

    var tool: ScreenshotTool?
    var textRecognitionState: TextRecognitionState = .idle
    var isShowingExportOptions = false
    var qualityPreset: ScreenshotQualityPreset = .medium {
        didSet { UserDefaults.standard.set(qualityPreset.rawValue, forKey: "screenshotQualityPreset") }
    }
    var customImageFormat: ScreenshotImageFormat = .jpg {
        didSet { UserDefaults.standard.set(customImageFormat.rawValue, forKey: "screenshotCustomImageFormat") }
    }
    var customScalePercent = 100 {
        didSet { UserDefaults.standard.set(customScalePercent, forKey: "screenshotCustomScalePercent") }
    }
    var customJPEGQualityPercent = 75 {
        didSet { UserDefaults.standard.set(customJPEGQualityPercent, forKey: "screenshotCustomJPEGQualityPercent") }
    }
    var lineWidth: CGFloat = 2 {
        didSet { UserDefaults.standard.set(Double(lineWidth), forKey: "screenshotLineWidth") }
    }
    var colorIndex = 0 {
        didSet { UserDefaults.standard.set(colorIndex, forKey: "screenshotColorIndex") }
    }
    var brushWidth: CGFloat = 13 {
        didSet { UserDefaults.standard.set(Double(brushWidth), forKey: "screenshotBrushWidth") }
    }
    var mosaicWidth: CGFloat = 12 {
        didSet { UserDefaults.standard.set(Double(mosaicWidth), forKey: "screenshotMosaicWidth") }
    }
    var solidColorIndex = 4 {
        didSet { UserDefaults.standard.set(solidColorIndex, forKey: "screenshotSolidColorIndex") }
    }
    var fontSize: CGFloat = 24 {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "screenshotFontSize") }
    }
    let lineWidths: [CGFloat] = [2, 3, 4, 6]
    let brushWidths: [CGFloat] = [9, 13, 17, 21]
    let mosaicWidths: [CGFloat] = [9, 12, 18, 24]
    let fontSizes: [CGFloat] = [12, 18, 24, 32, 48]

    var canUndo = false
    var onChange: (() -> Void)?
    var onUndo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRecognizeText: (() -> Void)?

    let colors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 1, green: 0.77, blue: 0, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.75, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.41, blue: 0.98, alpha: 1),
        .black, NSColor(srgbRed: 0.56, green: 0.58, blue: 0.62, alpha: 1), .white
    ]

    init() {
        let defaults = UserDefaults.standard
        let width = CGFloat(defaults.double(forKey: "screenshotLineWidth"))
        lineWidth = lineWidths.contains(width) ? width : 2
        let diameter = CGFloat(defaults.double(forKey: "screenshotBrushWidth"))
        brushWidth = brushWidths.contains(diameter) ? diameter : 13
        let mosaicDiameter = CGFloat(defaults.double(forKey: "screenshotMosaicWidth"))
        mosaicWidth = mosaicWidths.contains(mosaicDiameter) ? mosaicDiameter : 12
        let index = defaults.integer(forKey: "screenshotColorIndex")
        colorIndex = colors.indices.contains(index) ? index : 0
        let solidIndex = defaults.object(forKey: "screenshotSolidColorIndex") as? Int ?? 4
        solidColorIndex = colors.indices.contains(solidIndex) ? solidIndex : 4
        let size = CGFloat(defaults.double(forKey: "screenshotFontSize"))
        fontSize = fontSizes.contains(size) ? size : 24
        restoreExportPreferences()
    }

    func restoreExportPreferences() {
        let defaults = UserDefaults.standard
        qualityPreset = ScreenshotQualityPreset(rawValue: defaults.string(forKey: "screenshotQualityPreset") ?? "") ?? .medium
        customImageFormat = ScreenshotImageFormat(rawValue: defaults.string(forKey: "screenshotCustomImageFormat") ?? "") ?? .jpg
        let scale = defaults.object(forKey: "screenshotCustomScalePercent") as? Int ?? 100
        customScalePercent = min(100, max(20, scale))
        let quality = defaults.object(forKey: "screenshotCustomJPEGQualityPercent") as? Int ?? 75
        customJPEGQualityPercent = min(95, max(65, quality))
    }

    var activeLineWidth: CGFloat {
        get {
            if tool == .mosaic { return mosaicWidth }
            return tool?.isBrush == true ? brushWidth : lineWidth
        }
        set {
            if tool == .mosaic {
                mosaicWidth = newValue
            } else if tool?.isBrush == true {
                brushWidth = newValue
            } else {
                lineWidth = newValue
            }
        }
    }

    var selectedColorIndex: Int {
        get { tool == .solid ? solidColorIndex : colorIndex }
        set {
            if tool == .solid { solidColorIndex = newValue } else { colorIndex = newValue }
        }
    }

    var color: NSColor { colors[selectedColorIndex] }

    var exportOptions: ScreenshotExportOptions {
        switch qualityPreset {
        case .high: return ScreenshotExportOptions()
        case .medium: return ScreenshotExportOptions(format: .jpg, scalePercent: 100, qualityPercent: 84)
        case .low: return ScreenshotExportOptions(format: .jpg, scalePercent: 75, qualityPercent: 78)
        case .custom:
            return ScreenshotExportOptions(format: customImageFormat, scalePercent: customScalePercent,
                                           qualityPercent: customImageFormat == .png ? 100 : customJPEGQualityPercent)
        }
    }
}

struct ScreenshotToolbar: View {
    @Bindable var state: ScreenshotEditorState

    private static let buttonWidth: CGFloat = 34
    private static let rowHeight: CGFloat = 46
    private static let optionsHeight: CGFloat = 48
    private static let exportOptionsHeight: CGFloat = 180
    private static let rowSpacing: CGFloat = 6
    private static let outerPadding: CGFloat = 4
    private static let horizontalPadding: CGFloat = 6
    private static var contentWidth: CGFloat {
        buttonWidth * CGFloat(ScreenshotTool.allCases.count + 5) + horizontalPadding * 2
    }

    static func layoutSize(hasOptions: Bool, showingExportOptions: Bool) -> CGSize {
        let height = showingExportOptions ? exportOptionsHeight : (hasOptions ? optionsHeight : 0)
        return CGSize(width: contentWidth + outerPadding * 2,
                      height: rowHeight + outerPadding * 2 + (height > 0 ? rowSpacing + height : 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack(spacing: 0) {
                ForEach(ScreenshotTool.allCases) { tool in
                    icon(tool.symbol, title: tool.title, selected: state.tool == tool,
                         size: toolIconSize(tool)) {
                        state.isShowingExportOptions = false
                        state.tool = state.tool == tool ? nil : tool
                        state.onChange?()
                    }
                }
                icon("arrow.uturn.backward", title: String(localized: "撤销（⌘Z）"), size: 18) { state.onUndo?() }
                    .overlay(alignment: .leading) {
                        Divider().frame(width: 1, height: 20).allowsHitTesting(false)
                    }
                    .disabled(!state.canUndo)
                Button {
                    state.isShowingExportOptions.toggle()
                    if state.isShowingExportOptions { state.tool = nil }
                    state.onChange?()
                } label: {
                    ScreenshotQualityIcon(preset: state.qualityPreset)
                        .foregroundStyle(state.isShowingExportOptions ? Color.blue : Color(nsColor: .darkGray))
                        .frame(width: 32, height: 32)
                        .background(state.isShowingExportOptions ? Color.blue.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .frame(width: Self.buttonWidth, height: Self.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "导出质量：\(state.qualityPreset.title)"))
                .accessibilityLabel(String(localized: "导出质量：\(state.qualityPreset.title)"))
                icon("arrow.down.to.line", title: String(localized: "保存为 \(state.exportOptions.format.title)"), size: 17) { state.onSave?() }
                icon("xmark", title: String(localized: "取消（Esc）"), size: 17, tint: .red) { state.onCancel?() }
                icon("checkmark", title: String(localized: "复制截图（Enter / 双击选区）"), tint: .green) { state.onCopy?() }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: Self.contentWidth, height: Self.rowHeight)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))

            if state.isShowingExportOptions {
                ScreenshotExportOptionsView(state: state)
                    .frame(width: Self.contentWidth, height: Self.exportOptionsHeight)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            } else if let tool = state.tool {
                let widths = tool == .mosaic ? state.mosaicWidths
                    : (tool.isBrush ? state.brushWidths : state.lineWidths)
                let diameters: [CGFloat] = [6, 8, 10, 12]
                HStack(spacing: 0) {
                    if tool == .text {
                        ForEach(state.fontSizes, id: \.self) { size in
                            Button {
                                state.fontSize = size
                                state.onChange?()
                            } label: {
                                Text("\(Int(size))")
                                    .font(.system(size: 16, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(state.fontSize == size ? .blue : .gray)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.optionsHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "字号 \(Int(size))"))
                            .accessibilityLabel(String(localized: "字号 \(Int(size))"))
                            .accessibilityAddTraits(state.fontSize == size ? .isSelected : [])
                        }
                    } else {
                        HStack(spacing: 0) {
                            ForEach(widths.indices, id: \.self) { index in
                                let width = widths[index]
                                let sizeLabel = tool.isBrush
                                    ? String(localized: "笔刷直径 \(Int(width))")
                                    : String(localized: "线宽 \(Int(width))")
                                Button {
                                    state.activeLineWidth = width
                                    state.onChange?()
                                } label: {
                                    Circle().fill(state.activeLineWidth == width ? Color.blue : Color.gray)
                                        .frame(width: diameters[index], height: diameters[index])
                                        .frame(width: 36, height: Self.optionsHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(sizeLabel)
                                .accessibilityLabel(sizeLabel)
                                .accessibilityAddTraits(state.activeLineWidth == width ? .isSelected : [])
                            }
                        }
                        .frame(maxWidth: tool == .mosaic ? .infinity : nil, alignment: .leading)
                    }
                    if tool != .mosaic {
                        ForEach(state.colors.indices, id: \.self) { index in
                            Button {
                                state.selectedColorIndex = index
                                state.onChange?()
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: state.colors[index]))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.4), lineWidth: 1))
                                    .overlay {
                                        if state.selectedColorIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(index == 1 || index == 6 ? .black : .white)
                                        }
                                    }
                                    .frame(width: 22, height: 22)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.optionsHeight)
                                    .contentShape(Rectangle())
                            }
                            .overlay(alignment: .leading) {
                                if index == state.colors.startIndex {
                                    Divider().frame(width: 1, height: 22).allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel([String(localized: "红色"), String(localized: "黄色"), String(localized: "绿色"), String(localized: "蓝色"), String(localized: "黑色"), String(localized: "灰色"), String(localized: "白色")][index])
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: Self.contentWidth, height: Self.optionsHeight)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .foregroundStyle(Color(nsColor: .darkGray))
        .fixedSize()
        .padding(Self.outerPadding)
        .environment(\.colorScheme, .light)
    }

    // 按字形的宽高和实心面积校准视觉大小，保持按钮点击区域一致。
    private func toolIconSize(_ tool: ScreenshotTool) -> CGFloat {
        switch tool {
        case .rectangle: return 17
        case .ellipse: return 19
        case .pen: return 20
        case .line, .arrow: return 20
        case .text: return 34
        case .mosaic, .solid: return 16
        }
    }

    private func icon(_ symbol: String, title: String, selected: Bool = false, size: CGFloat = 19,
                      tint: Color = Color(nsColor: .darkGray), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                // T 只显示系统符号的字母层，次级颜色透明以隐藏外框。
                .symbolRenderingMode(symbol == "t.square" ? .palette : .monochrome)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(selected ? .blue : tint, .clear)
                .frame(width: 32, height: 32)
                .background(selected ? Color.blue.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .frame(width: Self.buttonWidth, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct ScreenshotSelectionActions: View {
    let state: ScreenshotEditorState
    let dimensions: String
    let isVertical: Bool

    static let textColor = NSColor(srgbRed: 240.0 / 255, green: 240.0 / 255, blue: 240.0 / 255, alpha: 1)
    private static let rowHeight: CGFloat = 32

    private enum Segment: CaseIterable, Identifiable {
        case textRecognition
        case scrollingCapture

        var id: Self { self }

        var title: String {
            switch self {
            case .textRecognition: return String(localized: "文字识别")
            case .scrollingCapture: return String(localized: "滚动截图")
            }
        }
    }

    private static let segmentWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let widths = Segment.allCases.map { segment in
            let width = (segment.title as NSString).size(withAttributes: [.font: font]).width
            return width + (segment == .textRecognition ? 18 : 0)
        }
        return max(94, ceil(widths.max() ?? 0) + 20)
    }()

    private static func dimensionsWidth(_ dimensions: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        return ceil((dimensions as NSString).size(withAttributes: [.font: font]).width) + 20
    }

    static func layoutSize(dimensions: String, isVertical: Bool) -> CGSize {
        let count = CGFloat(Segment.allCases.count)
        let dimensionsWidth = Self.dimensionsWidth(dimensions)
        if isVertical {
            return CGSize(width: max(segmentWidth, dimensionsWidth), height: rowHeight * (count + 1))
        }
        return CGSize(width: dimensionsWidth + segmentWidth * count, height: rowHeight)
    }

    var body: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let dimensionsWidth = Self.dimensionsWidth(dimensions)
        let segmentWidth = isVertical ? max(Self.segmentWidth, dimensionsWidth) : Self.segmentWidth
        let foreground = Color(nsColor: Self.textColor)
        layout {
            Text(verbatim: dimensions)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(foreground)
                .frame(width: isVertical ? segmentWidth : dimensionsWidth, height: Self.rowHeight)
            ForEach(Segment.allCases) { segment in
                let isRecognition = segment == .textRecognition
                let status = state.textRecognitionState
                Button {
                    if isRecognition { state.onRecognizeText?() }
                } label: {
                    HStack(spacing: 4) {
                        if isRecognition {
                            if status == .recognizing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(foreground)
                                    .accessibilityHidden(true)
                            } else if let symbol = status.symbol {
                                Image(systemName: symbol)
                                    .foregroundStyle(status.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(segment.title)
                            .foregroundStyle(foreground)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: segmentWidth, height: Self.rowHeight)
                    .background(isRecognition && (status == .selecting || status == .result)
                                ? foreground.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isRecognition || status == .recognizing)
                .help(isRecognition ? status.title : segment.title)
                .accessibilityHint(isRecognition ? status.title : "")
                .overlay(alignment: isVertical ? .top : .leading) {
                    Rectangle()
                        .fill(foreground.opacity(0.2))
                        .frame(width: isVertical ? segmentWidth : 1, height: isVertical ? 1 : Self.rowHeight)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(.black)
        .clipShape(.rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(foreground.opacity(0.18))
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }
}
