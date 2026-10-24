import AppKit

@MainActor
final class ClipboardMonitor {
    private var task: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    private let store: ClipboardStore
    private let settings: SettingsManager
    private let pasteboard = NSPasteboard.general
    private let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PasteHub.clipboardImage"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let pollInterval: Duration = .milliseconds(400)

    init(store: ClipboardStore, settings: SettingsManager) {
        self.store = store
        self.settings = settings
        lastChangeCount = pasteboard.changeCount
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkClipboard()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func syncChangeCount() {
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Private

    private func checkClipboard() async {
        let capturedChangeCount = pasteboard.changeCount
        guard capturedChangeCount != lastChangeCount else { return }
        lastChangeCount = capturedChangeCount

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier

        if settings.isAppExcluded(bundleIdentifier: sourceBundleIdentifier) { return }

        let sourceApp = frontmostApp?.localizedName
        let types = pasteboard.types ?? []

        // 1) 文件 URL
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], !urls.isEmpty {
            store.add(urls.map { url in
                ClipboardItem(
                    type: .file,
                    content: url.absoluteString,
                    sourceApp: sourceApp,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
            })
            return
        }

        // 2) 图片
        if types.contains(.tiff) || types.contains(.png) {
            let png = pasteboard.data(forType: .png)
            if let data = png ?? pasteboard.data(forType: .tiff) {
                let isPNG = png != nil
                let fileURL = store.imagesDirectory.appendingPathComponent(UUID().uuidString + ".png")
                let job = BackgroundJob { () throws -> Bool in
                    try autoreleasepool {
                        let output: Data
                        if isPNG {
                            output = data
                        } else {
                            guard let bitmap = NSBitmapImageRep(data: data),
                                  let converted = bitmap.representation(using: .png, properties: [:]) else {
                                return false
                            }
                            output = converted
                        }
                        try output.write(to: fileURL, options: .atomic)
                        return true
                    }
                }
                do {
                    let written = try await job.value(on: imageQueue)
                    try Task.checkCancellation()
                    if written {
                        store.add(ClipboardItem(
                            type: .image,
                            content: fileURL.absoluteString,
                            sourceApp: sourceApp,
                            sourceBundleIdentifier: sourceBundleIdentifier
                        ))
                        return
                    }
                } catch is CancellationError {
                    // 等待正在进行的写入结束后清理，防止取消后留下未入库文件。
                    imageQueue.addOperation { try? FileManager.default.removeItem(at: fileURL) }
                    return
                } catch {
                    NSLog("Clipboard image write failed: %@", error.localizedDescription)
                }
                // 异步期间剪贴板可能已变，不将新内容归到上一次捕获的来源。
                guard pasteboard.changeCount == capturedChangeCount else { return }
            }
        }

        // 3) 纯文本
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            store.add(
                ClipboardItem(
                    type: .text,
                    content: string,
                    sourceApp: sourceApp,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
            )
        }
    }
}
