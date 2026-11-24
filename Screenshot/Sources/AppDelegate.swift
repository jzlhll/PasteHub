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
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ASimpleShot")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "截图 / 取色", action: #selector(startScreenshot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置...", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ASimpleShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        item.menu = menu
        statusItem = item
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
            window.title = "ASimpleShot 设置"
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
            settings.screenshotHotkeyRegistrationError = "无法监听截图快捷键（\(status)），仍可通过菜单栏开始截图。"
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
            : "截图快捷键注册失败（\(status)），可能已被占用，请更换组合。"
    }
}
