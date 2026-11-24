import AppKit
import Observation

@MainActor
@Observable
final class SettingsManager {
    private(set) var screenshotHotkeyKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(screenshotHotkeyKeyCode), forKey: "screenshotHotkeyKeyCode") }
    }

    private(set) var screenshotHotkeyModifiers: UInt {
        didSet { UserDefaults.standard.set(Int(screenshotHotkeyModifiers), forKey: "screenshotHotkeyModifiers") }
    }

    var screenshotHotkeyRegistrationError: String?
    var onHotkeyChanged: (() -> Void)?

    var screenshotMozJPEGEnabled: Bool {
        didSet { UserDefaults.standard.set(screenshotMozJPEGEnabled, forKey: "screenshotMozJPEGEnabled") }
    }

    init() {
        let defaults = UserDefaults.standard
        Self.migrateScreenshotPreferences(to: defaults)
        screenshotMozJPEGEnabled = defaults.object(forKey: "screenshotMozJPEGEnabled") as? Bool ?? true

        if let code = defaults.object(forKey: "screenshotHotkeyKeyCode") as? Int,
           let keyCode = UInt16(exactly: code) {
            screenshotHotkeyKeyCode = keyCode
        } else {
            screenshotHotkeyKeyCode = 0
        }

        if let modifiers = defaults.object(forKey: "screenshotHotkeyModifiers") as? Int, modifiers > 0 {
            screenshotHotkeyModifiers = UInt(modifiers)
        } else {
            screenshotHotkeyModifiers = NSEvent.ModifierFlags([.option, .shift]).rawValue
        }
    }

    func setScreenshotHotkey(keyCode: UInt16, modifiers: UInt) {
        screenshotHotkeyKeyCode = keyCode
        screenshotHotkeyModifiers = modifiers
        onHotkeyChanged?()
    }

    var screenshotHotkeyDisplayString: String {
        Self.displayString(for: screenshotHotkeyKeyCode, modifiers: screenshotHotkeyModifiers)
    }

    // 从拆分前的固定签名版或默认 Xcode 版迁移截图偏好，保留 Screenshot 中已有的值。
    private static func migrateScreenshotPreferences(to defaults: UserDefaults) {
        let migrationKey = "didMigrateScreenshotPreferences"
        guard !defaults.bool(forKey: migrationKey) else { return }
        let screenshotKeys = [
            "screenshotHotkeyKeyCode", "screenshotHotkeyModifiers", "screenshotMozJPEGEnabled",
            "screenshotQualityPreset", "screenshotCustomImageFormat", "screenshotCustomScalePercent",
            "screenshotCustomJPEGQualityPercent", "screenshotLineWidth", "screenshotColorIndex",
            "screenshotBrushWidth", "screenshotMosaicWidth", "screenshotSolidColorIndex", "screenshotFontSize",
        ]
        for domain in ["top.yayalu.PasteHub", "com.example.PasteHub"] {
            guard let legacy = defaults.persistentDomain(forName: domain),
                  screenshotKeys.contains(where: { legacy[$0] != nil }) else { continue }
            for key in screenshotKeys where defaults.object(forKey: key) == nil {
                if let value = legacy[key] {
                    defaults.set(value, forKey: key)
                }
            }
            break
        }
        defaults.set(true, forKey: migrationKey)
    }

    nonisolated private static func displayString(for keyCode: UInt16, modifiers: UInt) -> String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { s += "\u{2303}" }
        if flags.contains(.option) { s += "\u{2325}" }
        if flags.contains(.shift) { s += "\u{21E7}" }
        if flags.contains(.command) { s += "\u{2318}" }
        s += Self.keyName(for: keyCode)
        return s
    }

    nonisolated static func keyName(for keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "\u{23CE}", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 48: "\u{21E5}", 49: "\u{2423}", 50: "`", 51: "\u{232B}", 53: "\u{238B}",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15",
            118: "F4", 120: "F2", 122: "F1",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}
