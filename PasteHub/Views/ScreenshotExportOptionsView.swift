import SwiftUI

// 图片内部线条的断裂程度表示质量，自定义在中档底图上叠加画笔。
struct ScreenshotQualityIcon: View {
    let preset: ScreenshotQualityPreset

    var body: some View {
        ZStack {
            Path(roundedRect: CGRect(x: 1.5, y: 3, width: 17, height: 14), cornerRadius: 2)
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if preset == .low {
                ForEach([30.0, 210.0], id: \.self) { angle in
                    Path { path in
                        path.addArc(center: CGPoint(x: 5.6, y: 6.5), radius: 1.15,
                                    startAngle: .degrees(angle), endAngle: .degrees(angle + 120), clockwise: false)
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            } else {
                Path(ellipseIn: CGRect(x: 4.5, y: 5.3, width: 2.3, height: 2.3))
                    .fill(.foreground)
            }
            Path { path in
                for points in mountainSegments {
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            if preset == .custom {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .background {
                        Capsule()
                            .fill(.white)
                            .frame(width: 6, height: 15)
                            .rotationEffect(.degrees(45))
                    }
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 20, height: 20)
        .scaleEffect(1.1)
        .accessibilityHidden(true)
    }

    private var mountainSegments: [[CGPoint]] {
        switch preset {
        case .high:
            return [[CGPoint(x: 3, y: 14.5), CGPoint(x: 7, y: 9), CGPoint(x: 10.5, y: 12.8),
                     CGPoint(x: 13.5, y: 9.5), CGPoint(x: 17, y: 14)]]
        case .medium, .custom:
            return [
                [CGPoint(x: 3, y: 14.5), CGPoint(x: 6, y: 10.4)],
                [CGPoint(x: 7.5, y: 9.5), CGPoint(x: 10.5, y: 12.8), CGPoint(x: 11.6, y: 11.6)],
                [CGPoint(x: 13.6, y: 9.7), CGPoint(x: 17, y: 14)]
            ]
        case .low:
            return [
                [CGPoint(x: 3.2, y: 14.8), CGPoint(x: 4.4, y: 13.1)],
                [CGPoint(x: 5.8, y: 11.3), CGPoint(x: 6.8, y: 9.8)],
                [CGPoint(x: 8.5, y: 10.1), CGPoint(x: 9.7, y: 11.5)],
                [CGPoint(x: 11.3, y: 12.9), CGPoint(x: 12.5, y: 11.4)],
                [CGPoint(x: 14.3, y: 10.7), CGPoint(x: 15.7, y: 12.4)],
                [CGPoint(x: 16.5, y: 14.2), CGPoint(x: 17.1, y: 15)]
            ]
        }
    }
}

struct ScreenshotExportOptionsView: View {
    @Bindable var state: ScreenshotEditorState

    private var isCustom: Bool { state.qualityPreset == .custom }
    private var canAdjustQuality: Bool { isCustom && state.customImageFormat == .jpg }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                rowLabel("预设")
                HStack(spacing: 4) {
                    ForEach(ScreenshotQualityPreset.allCases) { preset in
                        Button { state.qualityPreset = preset } label: {
                            HStack(spacing: 6) {
                                ScreenshotQualityIcon(preset: preset)
                                Text(preset.title).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(state.qualityPreset == preset ? Color.blue : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(state.qualityPreset == preset ? Color.blue.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.title)质量")
                        .accessibilityAddTraits(state.qualityPreset == preset ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                rowLabel("格式")
                HStack(spacing: 4) {
                    ForEach(ScreenshotImageFormat.allCases) { format in
                        formatOption(format)
                    }
                }
            }
            HStack(spacing: 10) {
                rowLabel("缩放")
                Slider(value: Binding(get: { Double(state.exportOptions.scalePercent) },
                                      set: { state.customScalePercent = Int($0.rounded()) }), in: 20...100)
                    .controlSize(.small)
                    .disabled(!isCustom)
                    .accessibilityLabel("尺寸缩放百分比")
                percentage(state.exportOptions.scalePercent)
            }
            .opacity(isCustom ? 1 : 0.6)
            HStack(spacing: 10) {
                rowLabel("质量")
                Slider(value: Binding(get: { Double(min(90, max(50, state.exportOptions.qualityPercent))) },
                                      set: { state.customJPEGQualityPercent = Int($0.rounded()) }), in: 50...90)
                    .controlSize(.small)
                    .disabled(!canAdjustQuality)
                    .accessibilityLabel("JPG质量百分比")
                percentage(state.exportOptions.qualityPercent)
            }
            .opacity(canAdjustQuality ? 1 : 0.6)
        }
        .padding(12)
    }

    private func formatOption(_ format: ScreenshotImageFormat) -> some View {
        let selected = state.exportOptions.format == format
        let label = Text(format.title)
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? (isCustom ? Color.blue : Color(nsColor: .darkGray)) : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(selected ? (isCustom ? Color.blue.opacity(0.1) : Color.black.opacity(0.12)) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        return Group {
            if isCustom {
                Button { state.customImageFormat = format } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .accessibilityLabel("\(format.title)格式")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .leading)
    }

    private func percentage(_ value: Int) -> some View {
        Text("\(value)%")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
    }
}
