import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// 管理截图会话、权限与导出，所有窗口和异步任务随会话结束统一清理。
@MainActor
final class ScreenshotService {
    private var captureTask: Task<Void, Never>?
    private var textRecognitionTask: Task<Void, Never>?
    private let textRecognitionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PasteHub.screenshotTextRecognition"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var windows: [ScreenshotWindow] = []
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var activeView: ScreenshotOverlayView?
    private var previousApp: NSRunningApplication?
    private var isShowingPermission = false
    private var savePanel: NSSavePanel?
    private var toastWindow: NSPanel?
    private var toastTask: Task<Void, Never>?

    var isActive: Bool { captureTask != nil || !windows.isEmpty || isShowingPermission }

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func start() {
        guard !isActive else { return }
        isShowingPermission = true
        defer { isShowingPermission = false }
        guard Self.hasScreenRecordingPermission || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "PasteHub 需要读取屏幕来截图和取色。请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 PasteHub。授权后再次按截图快捷键；若仍未生效，请退出并重新打开应用。截图不会录制音频。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { Self.openScreenRecordingSettings() }
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                let screens = NSScreen.screens
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                var captures: [(NSScreen, CGImage)] = []
                for screen in screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    filter.includeMenuBar = true
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
                    configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.captureResolution = .best
                    configuration.colorSpaceName = CGColorSpace.sRGB
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    captures.append((screen, image))
                }
                guard !captures.isEmpty else { throw ScreenshotError.noDisplay }
                try Task.checkCancellation()
                self.captureTask = nil
                self.present(captures)
            } catch {
                guard !Task.isCancelled else { return }
                self.cancel()
                self.showError("无法开始截图", detail: error.localizedDescription)
            }
        }
    }

    private func present(_ captures: [(NSScreen, CGImage)]) {
        for (screen, image) in captures {
            let view = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image)
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                if let selected = self.activeView, selected.selection != nil, selected !== view { return }
                self.activeView = view
                view.window?.makeKey()
            }
            view.onSelect = { [weak self, weak view] in
                guard let self, let view else { return }
                view.editor.restoreExportPreferences()
                self.activeView = view
                for window in self.windows {
                    if let other = window.contentView as? ScreenshotOverlayView, other !== view { other.resetSelection() }
                }
            }
            view.editor.onCancel = { [weak self] in self?.cancel() }
            view.onEdit = { [weak self] in self?.cancelTextRecognition() }
            view.editor.onRecognizeText = { [weak self, weak view] in
                guard let view else { return }
                guard self?.activeView === view else { return }
                view.beginTextRecognitionSelection()
            }
            view.onRecognizeText = { [weak self, weak view] region in
                guard let view else { return }
                self?.recognizeText(from: view, in: region)
            }
            view.onCopyRecognizedText = { [weak self, weak view] text in
                guard let self, let view else { return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    self.showToast("复制失败，请重试", on: view.window?.screen)
                    return
                }
                self.showToast("文字已复制到剪贴板", on: view.window?.screen)
            }
            view.editor.onCopy = { [weak self, weak view] in
                guard let view else { return }
                self?.copyScreenshot(from: view)
            }
            view.editor.onSave = { [weak self, weak view] in
                guard let view else { return }
                self?.saveScreenshot(from: view)
            }
            let window = ScreenshotWindow(contentRect: screen.frame, styleMask: .borderless,
                                          backing: .buffered, defer: false, screen: screen)
            window.contentView = view
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.hasShadow = false
            window.orderFrontRegardless()
            windows.append(window)
            if screen.frame.contains(NSEvent.mouseLocation) { activeView = view }
        }
        activeView = activeView ?? windows.first?.contentView as? ScreenshotOverlayView
        activeView?.window?.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if savePanel != nil { return event }
        if event.type == .flagsChanged {
            for window in windows {
                (window.contentView as? ScreenshotOverlayView)?.handleModifiers(event.modifierFlags)
            }
            return event
        }
        if let view = activeView, view.isTextRecognitionActive {
            return view.handleTextRecognitionKeyEvent(event) ? nil : event
        }
        // 文字输入期间由原生编辑器处理输入法、换行、复制、粘贴与撤销。
        if let view = activeView, view.isEditingText {
            return view.handleTextKeyEvent(event) ? nil : event
        }
        if event.keyCode == 53 { cancel(); return nil }
        guard let view = activeView else { return event }
        if event.keyCode == 17, view.selection != nil,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            view.editor.isShowingExportOptions = false
            view.editor.tool = view.editor.tool == .text ? nil : .text
            view.editor.onChange?()
            return nil
        }
        if event.modifierFlags.contains(.command), event.keyCode == 8 {
            if view.selection != nil {
                copyScreenshot(from: view)
            } else if let color = view.colorValue {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(color, forType: .string) else {
                    showError("复制失败", detail: "无法写入系统剪贴板，请重试。")
                    return nil
                }
                let screen = view.window?.screen
                cancel()
                showToast("已复制色值 \(color)", on: screen)
            }
            return nil
        }
        if event.modifierFlags.contains(.command), event.keyCode == 6 {
            view.undoAnnotation()
            return nil
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if view.selection != nil { copyScreenshot(from: view) }
            return nil
        }
        return event
    }

    func cancel() {
        cancelTextRecognition()
        captureTask?.cancel()
        captureTask = nil
        savePanel?.cancel(nil)
        savePanel = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        activeView = nil
        previousApp?.activate()
        previousApp = nil
    }

    private func copyScreenshot(from view: ScreenshotOverlayView) {
        cancelTextRecognition()
        let options = view.editor.exportOptions
        guard let image = view.exportImage(),
              let data = options.encodedData(from: image) else {
            showError("截图导出失败", detail: "无法生成截图，请重新选择区域。")
            return
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: options.format.pasteboardType)
        // 兼容数据也从最终编码结果生成，避免粘贴时绕过缩放和 JPG 质量设置。
        if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            showError("复制失败", detail: "无法写入系统剪贴板，请重试。")
            return
        }
        let screen = view.window?.screen
        cancel()
        showToast("截图已复制到剪贴板", on: screen)
    }

    private func recognizeText(from view: ScreenshotOverlayView, in region: CGRect) {
        guard view.selection != nil, view.editor.textRecognitionState == .selecting else { return }
        textRecognitionTask?.cancel()
        view.editor.textRecognitionState = .recognizing
        textRecognitionTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try Task.checkCancellation()
                guard let image = view.exportTextRecognitionImage(in: region) else { throw TextRecognitionError.invalidImage }
                let queue = self.textRecognitionQueue
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await Self.recognizeText(in: image, on: queue) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw TextRecognitionError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? ""
                }
                try Task.checkCancellation()
                guard self.activeView === view, view.editor.textRecognitionState == .recognizing else { return }
                guard !text.isEmpty else { throw TextRecognitionError.noText }
                view.showRecognizedText(text)
                self.textRecognitionTask = nil
                return
            } catch {
                guard !Task.isCancelled, self.activeView === view else { return }
                if case TextRecognitionError.timedOut = error {
                    view.editor.textRecognitionState = .timedOut
                } else {
                    let message = (error as? TextRecognitionError)?.errorDescription ?? "提取失败，请重试"
                    view.editor.textRecognitionState = .failed(message)
                }
                if !(error is TextRecognitionError) {
                    NSLog("Screenshot text recognition failed: %@", error.localizedDescription)
                }
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            view.resumeTextRecognitionSelection()
            self.textRecognitionTask = nil
        }
    }

    // 复用 BackgroundJob 的取消与等待机制，超时后立即结束等待并丢弃迟到的结果。
    nonisolated private static func recognizeText(in image: CGImage, on queue: OperationQueue) async throws -> String {
        let request = VNRecognizeTextRequest()
        let job = BackgroundJob(cancellableWork: { operation in
            try autoreleasepool {
                guard !operation.isCancelled else { throw CancellationError() }
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                request.usesLanguageCorrection = true
                let supportedLanguages = try request.supportedRecognitionLanguages()
                let languages = ["zh-Hans", "zh-Hant", "en-US"].filter { supportedLanguages.contains($0) }
                if !languages.isEmpty { request.recognitionLanguages = languages }
                guard !operation.isCancelled else { throw CancellationError() }
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                guard !operation.isCancelled else { throw CancellationError() }
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        })
        return try await withTaskCancellationHandler {
            try await job.value(on: queue)
        } onCancel: {
            request.cancel()
        }
    }

    private func cancelTextRecognition() {
        textRecognitionTask?.cancel()
        textRecognitionTask = nil
        for window in windows {
            (window.contentView as? ScreenshotOverlayView)?.resetTextRecognition()
        }
    }

    private func saveScreenshot(from view: ScreenshotOverlayView) {
        cancelTextRecognition()
        guard savePanel == nil else { return }
        let options = view.editor.exportOptions
        guard let image = view.exportImage(), let data = options.encodedData(from: image) else {
            showError("截图导出失败", detail: "无法生成截图，请重新选择区域。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "截图-\(Date().formatted(.dateTime.year().month().day().hour().minute().second()).replacingOccurrences(of: ":", with: "-" )).\(options.format.rawValue)"
        panel.title = "保存截图"
        savePanel = panel
        // 原生保存面板需要位于截图蒙层上方，取消保存后恢复编辑。
        for window in windows { window.level = .normal }
        panel.level = .screenSaver
        panel.begin { [weak self, weak view] response in
            guard let self, self.savePanel === panel else { return }
            self.savePanel = nil
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url, options: .atomic)
                    let screen = view?.window?.screen
                    self.cancel()
                    self.showToast("截图已保存", on: screen)
                    return
                } catch {
                    self.showError("保存失败", detail: error.localizedDescription)
                }
            }
            for window in self.windows { window.level = .screenSaver; window.orderFrontRegardless() }
            view?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.window.level = .screenSaver
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showToast(_ message: String, on screen: NSScreen? = nil) {
        toastTask?.cancel()
        toastWindow?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let width = max(260, label.intrinsicContentSize.width + 48)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let height = labelHeight + 26
        let panel = NSPanel(contentRect: CGRect(x: frame.midX - width / 2,
                                               y: frame.maxY - frame.height / 5 - height / 2,
                                               width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 12
        label.frame = CGRect(x: 16, y: (height - labelHeight) / 2, width: width - 32, height: labelHeight)
        container.addSubview(label)
        panel.contentView = container
        panel.orderFrontRegardless()
        toastWindow = panel
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            panel.orderOut(nil)
            self?.toastWindow = nil
            self?.toastTask = nil
        }
    }
}

private enum TextRecognitionError: LocalizedError {
    case invalidImage
    case noText
    case timedOut

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法生成截图，请重新选择区域"
        case .noText: return "未识别到文字，请重试"
        case .timedOut: return "提取超时，请重试"
        }
    }
}

private enum ScreenshotError: LocalizedError {
    case noDisplay
    nonisolated var errorDescription: String? { "没有可用的显示器，请检查显示器连接与屏幕录制权限。" }
}

private final class ScreenshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
