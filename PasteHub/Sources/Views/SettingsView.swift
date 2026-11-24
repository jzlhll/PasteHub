import SwiftUI
import AppKit
import ApplicationServices

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case hotkey
    case excludedApps
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .hotkey: return String(localized: "快捷键")
        case .excludedApps: return String(localized: "排除应用")
        case .about: return String(localized: "关于")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .hotkey: return "keyboard"
        case .excludedApps: return "hand.raised.slash"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    var settings: SettingsManager
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.system(size: 15))
                        .padding(.vertical, 7)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 280)
        } detail: {
            Group {
                if let selection {
                    SettingsDetailView(section: selection, settings: settings)
                } else {
                    ContentUnavailableView(String(localized: "选择设置项"), systemImage: "sidebar.left")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 600)
    }
}

private struct SettingsDetailView: View {
    let section: SettingsSection
    let settings: SettingsManager

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general:
            GeneralTab(settings: settings)
        case .hotkey:
            HotkeyTab(settings: settings)
        case .excludedApps:
            ExcludedAppsTab(settings: settings)
        case .about:
            AboutTab()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(section: section)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsPageHeader: View {
    let section: SettingsSection

    var body: some View {
        HStack {
            Text(section.title)
                .font(.system(size: 28, weight: .bold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

private struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        title = ""
        subtitle = nil
        self.content = content()
    }

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                        }
                }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessoryColumnWidth: CGFloat
    let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        accessoryColumnWidth: CGFloat = 220,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessoryColumnWidth = accessoryColumnWidth
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            accessory
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .frame(width: accessoryColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsMetricRow: View {
    let title: String
    let value: String
    var allowsSelection: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 12)

            Group {
                if allowsSelection {
                    Text(value)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.35))
            .frame(height: 1)
    }
}

private struct CompactDensitySkeletonPicker: View {
    @Binding var selection: CompactDensity

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CompactDensity.allCases) { density in
                Button {
                    selection = density
                } label: {
                    VStack(spacing: 7) {
                        CompactDensitySkeletonPreview(density: density)
                            .frame(height: 58)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)

                        Text(density.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selection == density ? Color.accentColor : .primary)
                            .padding(.bottom, 6)
                    }
                    .frame(width: 104)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                selection == density ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.45),
                                lineWidth: selection == density ? 1.5 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CompactDensitySkeletonPreview: View {
    let density: CompactDensity

    private var rowCount: Int {
        density == .high ? 4 : 3
    }

    private var rowHeight: CGFloat {
        density == .high ? 6 : 8
    }

    private var rowSpacing: CGFloat {
        density == .high ? 3 : 4
    }

    private var iconWidth: CGFloat {
        density == .high ? 8 : 9
    }

    private var verticalPadding: CGFloat {
        switch density {
        case .low: return 8
        case .medium: return 6
        case .high: return 5
        }
    }

    private var placeholderColor: Color {
        Color.secondary.opacity(0.34)
    }

    @ViewBuilder
    private var previewContent: some View {
        if density == .low {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    waterfallCard(height: 17)
                    waterfallCard(height: 11)
                }

                VStack(spacing: 4) {
                    waterfallCard(height: 11)
                    waterfallCard(height: 17)
                }
            }
        } else {
            VStack(spacing: rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { _ in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(placeholderColor.opacity(0.75))
                            .frame(width: iconWidth, height: rowHeight)

                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(placeholderColor)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                    }
                }
            }
        }
    }

    private func waterfallCard(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(placeholderColor)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    var body: some View {
        previewContent
        .padding(.horizontal, 6)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: SettingsManager

    private let countOptions = [10, 20, 50, 100, 200, 500]

    private var compactPositionOptions: [CompactPanelPosition] {
        CompactPanelPosition.availablePositions(for: settings.compactDensity)
    }

    private var isCompactSizeLocked: Bool {
        settings.compactDensity == .high && settings.compactPanelPosition == .followMouse
    }

    private var compactDensitySubtitle: String {
        String(localized: "控制同屏可见条目数和单条信息详略。界面越紧凑，同屏显示越多。")
    }

    private var compactDensityStateHint: String {
        switch settings.compactDensity {
        case .low:
            return String(localized: "当前档位：宽松。使用卡片瀑布流，单条信息展示更完整，同屏条目较少。")
        case .medium:
            return String(localized: "当前档位：均衡。使用线性列表，保留标题与来源信息，同屏条目更多。")
        case .high:
            return String(localized: "当前档位：紧凑。使用极简线性列表，同屏条目最多，适合快速定位。")
        }
    }

    private var compactPositionSubtitle: String {
        if settings.compactDensity == .high {
            return String(localized: "当前档位支持“状态栏图标处 / 跟随鼠标指针 / 屏幕中间”。")
        }
        return String(localized: "当前档位不支持“跟随鼠标指针”，仅支持“状态栏图标处 / 屏幕中间”。")
    }

    private var compactSizeSubtitle: String {
        if isCompactSizeLocked {
            return String(localized: "当前组合固定为 10 条列表高度，面板大小不生效。")
        }
        return String(localized: "小 / 中 / 大分别按屏幕高度的 45% / 60% / 75% 计算。")
    }

    private var compactPanelStateHint: String {
        if isCompactSizeLocked {
            return String(localized: "当前状态：紧凑 + 跟随鼠标指针。面板固定为最近 10 条，优先快速粘贴。")
        }
        return String(localized: "当前状态：\(settings.compactDensity.title)档位 · \(settings.compactPanelPosition.title) · 面板\(settings.compactPanelSize.title)尺寸。")
    }

    var body: some View {
        SettingsPane {
            SettingsCard(
                title: String(localized: "历史记录"),
                subtitle: ""
            ) {
                SettingsRow(
                    title: String(localized: "最大保留条数"),
                    subtitle: String(localized: "超过上限后，旧记录会自动按时间清理。")
                ) {
                    Picker(String(localized: "最大保留条数"), selection: $settings.maxHistoryCount) {
                        ForEach(countOptions, id: \.self) { count in
                            Text(String(localized: "\(count) 条")).tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120, alignment: .trailing)
                }
            }

            SettingsCard(
                title: String(localized: "系统"),
                subtitle: ""
            ) {
                SettingsRow(
                    title: String(localized: "开机自动启动"),
                    subtitle: String(localized: "登录后自动在后台启动 PasteHub。")
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsCard(
                title: String(localized: "面板"),
                subtitle: ""
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(
                        title: String(localized: "紧凑模式"),
                        subtitle: String(localized: "开启后，单击状态栏图标会直接弹出紧凑面板。")
                    ) {
                        Toggle("", isOn: $settings.compactModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    SettingsSeparator()

                    if settings.compactModeEnabled {
                        SettingsRow(
                            title: String(localized: "显示密度"),
                            subtitle: compactDensitySubtitle,
                            accessoryColumnWidth: 340
                        ) {
                            CompactDensitySkeletonPicker(selection: $settings.compactDensity)
                        }

                        SettingsHint(text: compactDensityStateHint)

                        SettingsSeparator()

                        SettingsRow(
                            title: String(localized: "紧凑面板位置"),
                            subtitle: compactPositionSubtitle
                        ) {
                            Picker(String(localized: "紧凑面板位置"), selection: $settings.compactPanelPosition) {
                                ForEach(compactPositionOptions) { position in
                                    Text(position.title).tag(position)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 170, alignment: .trailing)
                        }

                        SettingsSeparator()

                        SettingsRow(
                            title: String(localized: "紧凑面板大小"),
                            subtitle: compactSizeSubtitle
                        ) {
                            Picker(String(localized: "紧凑面板大小"), selection: $settings.compactPanelSize) {
                                ForEach(CompactPanelSize.allCases) { size in
                                    Text(size.title).tag(size)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 210, alignment: .trailing)
                            .disabled(isCompactSizeLocked)
                        }

                        SettingsHint(text: compactPanelStateHint)
                    } else {
                        SettingsRow(
                            title: String(localized: "默认弹出位置"),
                            subtitle: String(localized: "非紧凑模式下，从这个方向展开主面板。")
                        ) {
                            Picker(String(localized: "弹出位置"), selection: $settings.panelEdge) {
                                ForEach(PanelEdge.allCases) { edge in
                                    Text(edge.title).tag(edge)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 110, alignment: .trailing)
                        }

                        SettingsHint(text: String(localized: "可随时开启紧凑模式，改为单击状态栏图标直接呼出。"))
                    }
                }
            }
        }
    }
}

// MARK: - Hotkey

private struct HotkeyTab: View {
    var settings: SettingsManager
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()
    @State private var lastCheckedAt = Date()

    private var executablePath: String {
        Bundle.main.executableURL?.path ?? String(localized: "未知")
    }

    private var bundlePath: String {
        Bundle.main.bundleURL.path
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? String(localized: "未知")
    }

    private var processID: String {
        String(ProcessInfo.processInfo.processIdentifier)
    }

    var body: some View {
        SettingsPane {
            SettingsCard(
                title: String(localized: "全局快捷键"),
                subtitle: ""
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(
                        title: String(localized: "显示 / 隐藏面板"),
                        subtitle: String(localized: "点击录制区域后直接按下新的快捷键组合，按 Esc 取消。")
                    ) {
                        HotkeyRecorderButton(
                            displayString: settings.hotkeyDisplayString,
                            onRecorded: { code, mods in
                                settings.setHotkey(keyCode: code, modifiers: mods)
                            }
                        )
                    }

                    SettingsSeparator()

                    SettingsHint(text: String(localized: "单击卡片会先复制内容，再尝试自动键入。首次授予辅助功能权限后建议重启 PasteHub。"))
                }
            }

            SettingsCard(
                title: String(localized: "其他内置入口"),
                subtitle: ""
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ShortcutRow(label: String(localized: "退出应用"), shortcut: "\u{2318}Q")
                    ShortcutRow(label: String(localized: "完成键入条目"), shortcut: String(localized: "单击卡片"))
                    ShortcutRow(label: String(localized: "重新复制 / 标签 / 删除"), shortcut: String(localized: "卡片按钮或右键菜单"))
                }
            }

            SettingsCard(
                title: String(localized: "辅助功能权限诊断"),
                subtitle: ""
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(title: String(localized: "辅助功能权限")) {
                        Text(isAccessibilityTrusted ? String(localized: "已授权") : String(localized: "未授权"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(isAccessibilityTrusted ? .green : .red)
                    }

                    SettingsSeparator()

                    SettingsMetricRow(title: "Bundle ID", value: bundleID, allowsSelection: true)
                    SettingsMetricRow(title: String(localized: "进程 PID"), value: processID, allowsSelection: true)
                    SettingsMetricRow(title: String(localized: "上次检测"), value: Self.timeFormatter.string(from: lastCheckedAt))

                    SettingsSeparator()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "当前可执行路径"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(executablePath)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "当前 Bundle 路径"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(bundlePath)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsSeparator()

                    HStack(spacing: 10) {
                        Button(String(localized: "刷新状态")) {
                            refreshAccessibilityState()
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "打开辅助功能设置")) {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "重置提示缓存")) {
                            PasteToAppService.resetAccessibilityPromptCache()
                            refreshAccessibilityState()
                        }
                        .buttonStyle(.bordered)
                    }

                    SettingsHint(text: String(localized: "若路径与你在系统“辅助功能”里勾选的 PasteHub 不一致，会导致一直提示未授权。"))
                }
            }
        }
        .onAppear {
            refreshAccessibilityState()
        }
    }

    private func refreshAccessibilityState() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        lastCheckedAt = Date()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Excluded Apps

private struct ExcludedAppsTab: View {
    @Bindable var settings: SettingsManager

    private var availableApps: [(name: String, bundleID: String, icon: NSImage)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName,
                      let id = app.bundleIdentifier,
                      let icon = app.icon,
                      !settings.excludedApps.contains(where: { $0.bundleIdentifier == id })
                else { return nil }
                return (name, id, icon)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SettingsPane {
            SettingsCard(
                title: String(localized: "排除应用"),
                subtitle: ""
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    if settings.excludedApps.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "hand.raised.slash")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(String(localized: "暂无排除应用"))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text(String(localized: "可从当前正在运行的应用里快速加入排除名单。"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(String(localized: "添加到这里的应用将不会被 PasteHub 记录"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(settings.excludedApps.enumerated()), id: \.element.id) { index, app in
                                HStack(spacing: 12) {
                                    appIcon(for: app.bundleIdentifier)
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(app.bundleIdentifier)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 12)

                                    Button(role: .destructive) {
                                        settings.excludedApps.removeAll { $0.id == app.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 12)

                                if index < settings.excludedApps.count - 1 {
                                    SettingsSeparator()
                                }
                            }
                        }
                    }

                    SettingsSeparator()

                    Menu {
                        ForEach(availableApps, id: \.bundleID) { app in
                            Button {
                                settings.excludedApps.append(
                                    ExcludedApp(bundleIdentifier: app.bundleID, name: app.name)
                                )
                            } label: {
                                Label {
                                    Text(app.name)
                                } icon: {
                                    Image(nsImage: app.icon)
                                }
                            }
                        }

                        if availableApps.isEmpty {
                            Text(String(localized: "无可添加的运行中应用"))
                        }
                    } label: {
                        Label(String(localized: "添加正在运行的应用"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
            }
        }
    }

    private func appIcon(for bundleID: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "app")
    }
}

// MARK: - About

private struct AboutTab: View {
    private let githubURL = URL(string: "https://github.com/lageev/PasteHub")!
    private let coolapkURL = URL(string: "https://www.coolapk.com")!
    private let xiaohongshuURL = URL(string: "https://www.xiaohongshu.com/user/profile/5ae19a3411be10493e3a5643")!
    private let weiboURL = URL(string: "https://weibo.com/u/1788149651")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPane {
                SettingsCard {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("PasteHub")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text(String(localized: "简洁高效的剪贴板助手"))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                }

            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    AboutIconLink(asset: "SocialXiaohongshu", tip: String(localized: "小红书"), destination: xiaohongshuURL)
                    AboutIconLink(asset: "SocialEmail", tip: String(localized: "邮箱"), destination: URL(string: "mailto:hfl1995@gmail.com")!)
                    AboutIconLink(asset: "SocialWeibo", tip: String(localized: "微博"), destination: weiboURL)
                    AboutFooterLink(icon: "cat.fill", label: "GitHub", destination: githubURL)
                    AboutFooterLink(icon: "heart.fill", label: String(localized: "酷安"), destination: coolapkURL)
                }

                Text("\(version)(\(build))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 18)
        }
    }
}

private struct AboutFooterLink: View {
    let icon: String
    let label: String
    let destination: URL
    @State private var isHovering = false

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isHovering ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : .clear)
            )
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
    }
}

private struct AboutIconLink: View {
    let asset: String
    let tip: String
    let destination: URL
    @State private var isHovering = false
    @State private var didCopy = false

    private var isMailLink: Bool {
        destination.scheme?.lowercased() == "mailto"
    }

    var body: some View {
        Button {
            if isMailLink {
                let email = destination.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .removingPercentEncoding?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !email.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(email, forType: .string)

                withAnimation(.easeOut(duration: 0.15)) {
                    didCopy = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        didCopy = false
                    }
                }
            } else {
                NSWorkspace.shared.open(destination)
            }
        } label: {
            HStack(spacing: 5) {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .saturation(isHovering ? 1 : 0)
                    .opacity(isHovering ? 1 : 0.55)

                Text(isMailLink && didCopy ? String(localized: "已复制") : tip)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle((isHovering || (isMailLink && didCopy)) ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill((isHovering || (isMailLink && didCopy)) ? Color.accentColor.opacity(0.08) : .clear)
            )
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.15), value: didCopy)
        }
        .buttonStyle(.plain)
        .help(isMailLink ? (didCopy ? String(localized: "已复制邮箱地址") : String(localized: "复制邮箱地址")) : tip)
    }
}

// MARK: - Hotkey Recorder

private struct HotkeyRecorderButton: View {
    let displayString: String
    let onRecorded: (UInt16, UInt) -> Void
    @State private var isRecording = false

    var body: some View {
        ZStack {
            if isRecording {
                KeyCatcher(
                    onKey: { code, flags in
                        onRecorded(code, flags.rawValue)
                        isRecording = false
                    },
                    onCancel: { isRecording = false }
                )
                .frame(width: 0, height: 0)
            }

            Button { isRecording = true } label: {
                Text(isRecording ? String(localized: "按下快捷键组合...") : displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct KeyCatcher: NSViewRepresentable {
    let onKey: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKey = onKey
        v.onCancel = onCancel
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {}

    class KeyCatcherView: NSView {
        var onKey: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modifierKeyCodes.contains(event.keyCode) else { return }

            if event.keyCode == 53 { onCancel?(); return }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control, .shift]).isEmpty else { return }

            onKey?(event.keyCode, flags)
        }
    }
}
