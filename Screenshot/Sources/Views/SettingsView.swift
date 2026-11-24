import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsManager
    @State private var hasScreenRecordingPermission = ScreenshotService.hasScreenRecordingPermission

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("截图 / 取色") {
                    HotkeyRecorderButton(
                        displayString: settings.screenshotHotkeyDisplayString,
                        onRecorded: { code, modifiers in
                            settings.setScreenshotHotkey(keyCode: code, modifiers: modifiers)
                        }
                    )
                }
                if let error = settings.screenshotHotkeyRegistrationError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("截图导出") {
                Toggle("MozJPEG 压缩", isOn: $settings.screenshotMozJPEGEnabled)
                Text("开启时使用 MozJPEG 编码 JPG，关闭时使用系统 JPG 编码器。")
                    .foregroundStyle(.secondary)
            }

            Section("权限") {
                LabeledContent("截图权限") {
                    Text(hasScreenRecordingPermission ? "已授权" : "未授权")
                        .foregroundStyle(hasScreenRecordingPermission ? .green : .red)
                }
                HStack {
                    Button("刷新状态") {
                        hasScreenRecordingPermission = ScreenshotService.hasScreenRecordingPermission
                    }
                    Button("打开系统设置") {
                        ScreenshotService.openScreenRecordingSettings()
                    }
                }
                Text("截图和取色需要读取屏幕内容。授权后若仍无法使用，请重新打开 ASimpleShot。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasScreenRecordingPermission = ScreenshotService.hasScreenRecordingPermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenRecordingPermission = ScreenshotService.hasScreenRecordingPermission
        }
    }
}

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
                Text(isRecording ? "按下快捷键组合..." : displayString)
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
