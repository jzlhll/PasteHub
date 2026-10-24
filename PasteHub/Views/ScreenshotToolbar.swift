import SwiftUI
import AppKit

@MainActor
@Observable
final class ScreenshotEditorState {
    var tool: ScreenshotTool?
    var lineWidth: CGFloat = 3
    var colorIndex = 0
    var brushWidth: CGFloat = 36
    var solidColorIndex = 4

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

    var colorValue: String {
        let color = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

struct ScreenshotToolbar: View {
    @Bindable var state: ScreenshotEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ScreenshotTool.allCases) { tool in
                    icon(tool.symbol, title: tool.title, selected: state.tool == tool) {
                        state.tool = state.tool == tool ? nil : tool
                        state.onChange?()
                    }
                }
                Divider().frame(height: 22).padding(.horizontal, 4)
                icon("arrow.uturn.backward", title: "撤销（⌘Z）") { state.onUndo?() }
                    .disabled(!state.canUndo)
                icon("arrow.down.to.line", title: "保存为 PNG") { state.onSave?() }
                icon("xmark", title: "取消（Esc）", tint: .red) { state.onCancel?() }
                icon("checkmark", title: "复制截图（Enter）", tint: .green) { state.onCopy?() }
            }
            .padding(8)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))

            if let tool = state.tool {
                let widths: [CGFloat] = tool.isBrush ? [24, 36, 48] : [3, 6, 9]
                HStack(spacing: 8) {
                    ForEach(widths, id: \.self) { width in
                        Button {
                            state.activeLineWidth = width
                            state.onChange?()
                        } label: {
                            Circle().fill(state.activeLineWidth == width ? Color.blue : Color.gray)
                                .frame(width: tool.isBrush ? width / 3 + 4 : width + 4,
                                       height: tool.isBrush ? width / 3 + 4 : width + 4)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("\(tool.isBrush ? "笔刷直径" : "线宽") \(Int(width))")
                        .accessibilityLabel("\(tool.isBrush ? "笔刷直径" : "线宽") \(Int(width))")
                    }
                    if tool != .mosaic {
                        Divider().frame(height: 24)
                        ForEach(state.colors.indices, id: \.self) { index in
                            Button {
                                state.selectedColorIndex = index
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: state.colors[index]))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.4)))
                                    .overlay {
                                        if state.selectedColorIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(index == 1 || index == 6 ? .black : .white)
                                        }
                                    }
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(["红色", "黄色", "绿色", "蓝色", "黑色", "灰色", "白色"][index])
                        }
                        if tool == .solid {
                            Text(state.colorValue)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .accessibilityLabel("当前色值 \(state.colorValue)")
                        }
                    }
                }
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .foregroundStyle(Color(nsColor: .darkGray))
        .fixedSize()
        .padding(4)
        .environment(\.colorScheme, .light)
    }

    private func icon(_ symbol: String, title: String, selected: Bool = false,
                      tint: Color = Color(nsColor: .darkGray), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(selected ? .blue : tint)
                .frame(width: 36, height: 36)
                .background(selected ? Color.blue.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
