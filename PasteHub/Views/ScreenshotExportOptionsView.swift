import SwiftUI

// 三级刻度表示质量高低，刻度叠加画笔表示用户自行调整的参数。
struct ScreenshotQualityIcon: View {
    let preset: ScreenshotQualityPreset

    var body: some View {
        Group {
            if preset == .custom {
                ZStack {
                    bars
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
            } else {
                bars
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.foreground)
                    .opacity(preset == .custom || level <= preset.level ? 1 : 0.18)
                    .frame(width: 4, height: CGFloat(4 + level * 4))
            }
        }
        .frame(width: 20, height: 20)
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
