import AppKit
import Carbon
import SwiftUI

// 管理截图应用的菜单栏入口、快捷键和设置窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsManager()
    private lazy var screenshotService = ScreenshotService(settings: settings)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        settings.onHotkeyChanged = { [weak self] in self?.registerHotKey() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if screenshotService.isActive {
            screenshotService.cancel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenshotService.cancel()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef) }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusItemIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "截图 / 取色"), action: #selector(startScreenshot), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "设置..."), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 ASimpleShot"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        item.menu = menu
        statusItem = item
    }

    private func makeStatusItemIcon() -> NSImage {
        let shade: CGFloat = 240.0 / 255
        let color = NSColor(srgbRed: shade, green: shade, blue: shade, alpha: 1)
        let camera = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let corners = NSBezierPath()
            let armLength: CGFloat = 5
            let edges: [(position: CGFloat, direction: CGFloat)] = [(2, 1), (18, -1)]
            for (x, horizontalDirection) in edges {
                for (y, verticalDirection) in edges {
                    let end = NSPoint(x: x, y: y + verticalDirection * armLength)
                    corners.move(to: NSPoint(x: x + horizontalDirection * armLength, y: y))
                    corners.appendArc(from: NSPoint(x: x, y: y), to: end, radius: 3)
                    corners.line(to: end)
                }
            }
            corners.lineWidth = 2
            corners.lineCapStyle = .round
            color.setStroke()
            corners.stroke()
            camera?.draw(in: NSRect(x: 5, y: 6, width: 10, height: 8))
            return true
        }
        icon.accessibilityDescription = "ASimpleShot"
        return icon
    }

    @objc private func startScreenshot() {
        guard !screenshotService.isActive else { return }
        settingsWindow?.close()
        screenshotService.start()
    }

    @objc private func showSettings() {
        guard !screenshotService.isActive else { return }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(settings: settings))
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "ASimpleShot 设置")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 360))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in delegate.startScreenshot() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        guard status == noErr else {
            settings.screenshotHotkeyRegistrationError = String(localized: "无法监听截图快捷键（\(status)），仍可通过菜单栏开始截图。")
            return
        }
        registerHotKey()
    }

    private func registerHotKey() {
        guard hotKeyHandlerRef != nil else { return }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil

        let flags = NSEvent.ModifierFlags(rawValue: settings.screenshotHotkeyModifiers)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let status = RegisterEventHotKey(
            UInt32(settings.screenshotHotkeyKeyCode),
            modifiers,
            EventHotKeyID(signature: OSType(0x5343524E), id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        settings.screenshotHotkeyRegistrationError = status == noErr
            ? nil
            : String(localized: "截图快捷键注册失败（\(status)），可能已被占用，请更换组合。")
    }
}
