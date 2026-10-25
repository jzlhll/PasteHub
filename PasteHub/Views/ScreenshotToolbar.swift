import SwiftUI
import AppKit

@MainActor
@Observable
final class ScreenshotEditorState {
    var tool: ScreenshotTool?
    var lineWidth: CGFloat = 2 {
        didSet { UserDefaults.standard.set(Double(lineWidth), forKey: "screenshotLineWidth") }
    }
    var colorIndex = 0 {
        didSet { UserDefaults.standard.set(colorIndex, forKey: "screenshotColorIndex") }
    }
    var brushWidth: CGFloat = 15 {
        didSet { UserDefaults.standard.set(Double(brushWidth), forKey: "screenshotBrushWidth") }
    }
    var solidColorIndex = 4 {
        didSet { UserDefaults.standard.set(solidColorIndex, forKey: "screenshotSolidColorIndex") }
    }
    var fontSize: CGFloat = 24 {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "screenshotFontSize") }
    }
    let fontSizes: [CGFloat] = [14, 18, 24, 32, 48]

    var canUndo = false
    var onChange: (() -> Void)?
    var onUndo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?

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
        lineWidth = [2, 4, 6].contains(width) ? width : 2
        let diameter = CGFloat(defaults.double(forKey: "screenshotBrushWidth"))
        brushWidth = [9, 15, 21].contains(diameter) ? diameter : 15
        let index = defaults.integer(forKey: "screenshotColorIndex")
        colorIndex = colors.indices.contains(index) ? index : 0
        let solidIndex = defaults.object(forKey: "screenshotSolidColorIndex") as? Int ?? 4
        solidColorIndex = colors.indices.contains(solidIndex) ? solidIndex : 4
        let size = CGFloat(defaults.double(forKey: "screenshotFontSize"))
        fontSize = fontSizes.contains(size) ? size : 24
    }

    var activeLineWidth: CGFloat {
        get { tool?.isBrush == true ? brushWidth : lineWidth }
        set {
            if tool?.isBrush == true { brushWidth = newValue } else { lineWidth = newValue }
        }
    }

    var selectedColorIndex: Int {
        get { tool == .solid ? solidColorIndex : colorIndex }
        set {
            if tool == .solid { solidColorIndex = newValue } else { colorIndex = newValue }
        }
    }

    var color: NSColor { colors[selectedColorIndex] }
}

struct ScreenshotToolbar: View {
    @Bindable var state: ScreenshotEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 6.4) {
            HStack(spacing: 0) {
                ForEach(ScreenshotTool.allCases) { tool in
                    icon(tool.symbol, title: tool.title, selected: state.tool == tool,
                         size: tool == .solid ? 14.4 : 16.8) {
                        state.tool = state.tool == tool ? nil : tool
                        state.onChange?()
                    }
                }
                icon("arrow.uturn.backward", title: "撤销（⌘Z）") { state.onUndo?() }
                    .overlay(alignment: .leading) {
                        Divider().frame(width: 0.8, height: 17.6).allowsHitTesting(false)
                    }
                    .disabled(!state.canUndo)
                icon("arrow.down.to.line", title: "保存为 PNG") { state.onSave?() }
                icon("xmark", title: "取消（Esc）", tint: .red) { state.onCancel?() }
                icon("checkmark", title: "复制截图（Enter）", tint: .green) { state.onCopy?() }
            }
            .frame(width: 380.8, height: 41.6)
            .background(.white, in: RoundedRectangle(cornerRadius: 9.6))

            if let tool = state.tool {
                let widths: [CGFloat] = tool.isBrush ? [9, 15, 21] : [2, 4, 6]
                let diameters: [CGFloat] = tool.isBrush ? [5.6, 8, 9.6] : [4.8, 6.4, 8]
                HStack(spacing: 0) {
                    if tool == .text {
                        ForEach(state.fontSizes, id: \.self) { size in
                            Button {
                                state.fontSize = size
                                state.onChange?()
                            } label: {
                                Text("\(Int(size))")
                                    .font(.system(size: 12, weight: state.fontSize == size ? .bold : .regular))
                                    .foregroundStyle(state.fontSize == size ? .blue : .gray)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44.8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("字号 \(Int(size))")
                            .accessibilityLabel("字号 \(Int(size))")
                            .accessibilityAddTraits(state.fontSize == size ? .isSelected : [])
                        }
                    } else {
                        ForEach(widths.indices, id: \.self) { index in
                            let width = widths[index]
                            Button {
                                state.activeLineWidth = width
                                state.onChange?()
                            } label: {
                                Circle().fill(state.activeLineWidth == width ? Color.blue : Color.gray)
                                    .frame(width: diameters[index], height: diameters[index])
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44.8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(tool.isBrush ? "笔刷直径" : "线宽") \(Int(width))")
                            .accessibilityLabel("\(tool.isBrush ? "笔刷直径" : "线宽") \(Int(width))")
                        }
                    }
                    if tool != .mosaic {
                        ForEach(state.colors.indices, id: \.self) { index in
                            Button {
                                state.selectedColorIndex = index
                                state.onChange?()
                            } label: {
                                RoundedRectangle(cornerRadius: 3.2)
                                    .fill(Color(nsColor: state.colors[index]))
                                    .overlay(RoundedRectangle(cornerRadius: 3.2).stroke(.gray.opacity(0.4), lineWidth: 0.8))
                                    .overlay {
                                        if state.selectedColorIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11.2, weight: .bold))
                                                .foregroundStyle(index == 1 || index == 6 ? .black : .white)
                                        }
                                    }
                                    .frame(width: 20.8, height: 20.8)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44.8)
                                    .contentShape(Rectangle())
                            }
                            .overlay(alignment: .leading) {
                                if index == state.colors.startIndex {
                                    Divider().frame(width: 0.8, height: 19.2).allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(["红色", "黄色", "绿色", "蓝色", "黑色", "灰色", "白色"][index])
                        }
                    }
                }
                .frame(width: 380.8, height: 44.8)
                .background(.white, in: RoundedRectangle(cornerRadius: 9.6))
            }
        }
        .foregroundStyle(Color(nsColor: .darkGray))
        .fixedSize()
        .padding(3.2)
        .environment(\.colorScheme, .light)
    }

    private func icon(_ symbol: String, title: String, selected: Bool = false, size: CGFloat = 16.8,
                      tint: Color = Color(nsColor: .darkGray), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "t" { Text("T") }
                else { Image(systemName: symbol) }
            }
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(selected ? .blue : tint)
                .frame(width: 28.8, height: 28.8)
                .background(selected ? Color.blue.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6.4))
                .frame(maxWidth: .infinity)
                .frame(height: 41.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
