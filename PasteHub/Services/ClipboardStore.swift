import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []
    private(set) var snippets: [SnippetItem] = []

    var maxItems: Int {
        let v = UserDefaults.standard.integer(forKey: "maxHistoryCount")
        return v > 0 ? v : 50
    }

    let imagesDirectory: URL
    var onClipboardWrite: (() -> Void)?

    private let storageURL: URL
    private let snippetStorageURL: URL
    private let maxTextLength = 20_000
    private var canSaveHistory = true
    private var pendingImageRemovals: [URL] = []
    private let persistenceQueue = DispatchQueue(label: "PasteHub.persistence", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("PasteHub")
        storageURL = appDir.appendingPathComponent("history.json")
        snippetStorageURL = appDir.appendingPathComponent("snippets.json")
        imagesDirectory = appDir.appendingPathComponent("Images")

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let historyLoaded = load()
        loadSnippets()
        if historyLoaded {
            pruneOrphanedImages()
            save()
        }
    }

    // MARK: - Public

    func add(_ item: ClipboardItem) {
        if insert(item) { save() }
    }

    func add(_ newItems: [ClipboardItem]) {
        var changed = false
        for item in newItems {
            if insert(item) { changed = true }
        }
        if changed { save() }
    }

    private func insert(_ item: ClipboardItem) -> Bool {
        var normalized = normalizedItem(item)

        if let first = items.first,
           first.type == normalized.type,
           first.content == normalized.content {
            return false
        }

        if let existingIndex = items.firstIndex(where: {
            $0.type == normalized.type && $0.content == normalized.content
        }) {
            let existing = items[existingIndex]
            if normalized.tags.isEmpty, !existing.tags.isEmpty {
                normalized = ClipboardItem(
                    id: normalized.id,
                    type: normalized.type,
                    content: normalized.content,
                    timestamp: normalized.timestamp,
                    sourceApp: normalized.sourceApp,
                    sourceBundleIdentifier: normalized.sourceBundleIdentifier,
                    tags: existing.tags
                )
            }
            items.remove(at: existingIndex)
        }

        items.insert(normalized, at: 0)
        trimExcessItems()
        return true
    }

    func applyHistoryLimit() {
        guard items.count > maxItems else { return }
        trimExcessItems()
        save()
    }

    func remove(_ item: ClipboardItem) {
        let removed = items.filter { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        cleanupImages(for: removed)
        save()
    }

    func clearAll() {
        cleanupImages(for: items)
        items.removeAll()
        save()
    }

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            pasteboard.setString(item.content, forType: .string)
        case .image:
            if let url = item.contentURL,
               let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let url = item.contentURL {
                pasteboard.writeObjects([url as NSURL])
            }
        }

        onClipboardWrite?()
    }

    func copySnippetToClipboard(_ snippet: SnippetItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.content, forType: .string)
        onClipboardWrite?()
    }

    func setTags(for itemID: UUID, tags: [String]) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let sanitized = Self.sanitizedTags(tags)
        let item = items[index]
        items[index] = ClipboardItem(
            id: item.id,
            type: item.type,
            content: item.content,
            timestamp: item.timestamp,
            sourceApp: item.sourceApp,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            tags: sanitized
        )
        save()
    }

    func addSnippet(title: String, content: String, tags: [String]) {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return }

        let sanitizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedTags = Self.sanitizedTags(tags)
        if let index = snippets.firstIndex(where: { $0.content == normalizedContent }) {
            snippets.remove(at: index)
        }

        snippets.insert(
            SnippetItem(
                title: sanitizedTitle,
                content: String(normalizedContent.prefix(maxTextLength)),
                tags: sanitizedTags
            ),
            at: 0
        )
        saveSnippets()
    }

    func updateSnippet(_ snippet: SnippetItem) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let normalizedContent = snippet.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return }
        snippets[index] = SnippetItem(
            id: snippet.id,
            title: snippet.title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: String(normalizedContent.prefix(maxTextLength)),
            tags: Self.sanitizedTags(snippet.tags),
            timestamp: snippet.timestamp
        )
        saveSnippets()
    }

    func removeSnippet(_ snippet: SnippetItem) {
        snippets.removeAll { $0.id == snippet.id }
        saveSnippets()
    }

    // MARK: - Persistence

    private func save() {
        guard canSaveHistory else { return }
        let items = items
        let url = storageURL
        let referenced = Set(items.compactMap { item -> URL? in
            guard item.type != .text else { return nil }
            return item.contentURL?.standardizedFileURL
        })
        let removals = pendingImageRemovals.filter { !referenced.contains($0) }
        pendingImageRemovals.removeAll()
        persistenceQueue.async {
            // 先保存不再引用这些图片的索引；写盘失败时保留图片以便恢复。
            guard Self.write(items, to: url) else { return }
            for image in removals { try? FileManager.default.removeItem(at: image) }
        }
    }

    func flushPendingWrites() {
        persistenceQueue.sync {}
    }

    @discardableResult
    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Persistence write failed: %@", error.localizedDescription)
            return false
        }
    }

    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: storageURL)
            items = try decoder.decode([ClipboardItem].self, from: data)
            trimExcessItems()
            return true
        } catch {
            // 读取失败时保留图片，并先备份原索引，避免后续复制覆盖唯一的恢复来源。
            let backup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("history-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
            } catch {
                canSaveHistory = false
                NSLog("History recovery backup failed: %@", error.localizedDescription)
            }
            NSLog("History could not be loaded; orphan image cleanup skipped")
            return false
        }
    }

    private func saveSnippets() {
        let snippets = snippets
        let url = snippetStorageURL
        persistenceQueue.async {
            Self.write(snippets, to: url)
        }
    }

    private func loadSnippets() {
        guard FileManager.default.fileExists(atPath: snippetStorageURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: snippetStorageURL),
              let decoded = try? decoder.decode([SnippetItem].self, from: data) else { return }
        snippets = decoded
    }

    private func cleanupImages(for removedItems: [ClipboardItem]) {
        let directory = imagesDirectory.standardizedFileURL
        let urls = removedItems.compactMap { item -> URL? in
            guard item.type == .image, let url = item.contentURL, url.isFileURL,
                  url.standardizedFileURL.deletingLastPathComponent() == directory else { return nil }
            return url
        }
        pendingImageRemovals.append(contentsOf: urls.map(\.standardizedFileURL))
    }

    private func trimExcessItems() {
        guard items.count > maxItems else { return }
        let removed = Array(items[maxItems...])
        items = Array(items.prefix(maxItems))
        cleanupImages(for: removed)
    }

    private func normalizedItem(_ item: ClipboardItem) -> ClipboardItem {
        guard item.type == .text, item.content.count > maxTextLength else { return item }
        let shortened = String(item.content.prefix(maxTextLength))
        return ClipboardItem(
            id: item.id,
            type: item.type,
            content: shortened,
            timestamp: item.timestamp,
            sourceApp: item.sourceApp,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            tags: item.tags
        )
    }

    private func pruneOrphanedImages() {
        // 恢复索引尚在时保留其图片，避免下次正常启动又删除恢复所需的数据。
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: storageURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ), !entries.contains(where: { $0.lastPathComponent.hasPrefix("history-unreadable-") }) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let referenced = Set(
            items.compactMap { item -> URL? in
                guard item.type == .image,
                      let url = item.contentURL,
                      url.isFileURL,
                      url.path.hasPrefix(imagesDirectory.path) else {
                    return nil
                }
                return url.standardizedFileURL
            }
        )

        for file in files {
            let normalized = file.standardizedFileURL
            if !referenced.contains(normalized) {
                pendingImageRemovals.append(normalized)
            }
        }
    }

    private static func sanitizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for tag in tags {
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if !seen.contains(value) {
                seen.insert(value)
                normalized.append(value)
            }
        }
        return normalized
    }
}
