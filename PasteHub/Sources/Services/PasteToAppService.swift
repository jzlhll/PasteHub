import AppKit
import ApplicationServices

@MainActor
final class PasteToAppService {
    private static let accessibilityPromptedKey = "accessibilityPromptedOnce"

    static func resetAccessibilityPromptCache() {
        UserDefaults.standard.removeObject(forKey: accessibilityPromptedKey)
    }

    private var targetBundleIdentifier: String?
    private var targetProcessIdentifier: pid_t?
    private var targetFocusedElement: RememberedAXElement?
    private var captureTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    private let accessibilityQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PasteHub.accessibility"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var targetFocusedElementProcessIdentifier: pid_t?

    func cancelPendingPaste() {
        pasteTask?.cancel()
        pasteTask = nil
    }

    func rememberFrontmostExternalApp() {
        cancelPendingPaste()
        captureTask?.cancel()
        targetFocusedElement = nil
        targetFocusedElementProcessIdentifier = nil
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            targetBundleIdentifier = nil
            targetProcessIdentifier = nil
            return
        }
        let pid = frontmost.processIdentifier
        targetBundleIdentifier = frontmost.bundleIdentifier
        targetProcessIdentifier = pid
        guard AXIsProcessTrusted() else { return }
        let job = BackgroundJob(cancellableWork: { operation in
            let search = AccessibilityFocusSearch(shouldContinue: { !operation.isCancelled })
            return search.captureFocusedElement(processIdentifier: pid)
        })
        captureTask = Task { [weak self] in
            guard let self else { return }
            guard let result = try? await job.value(on: accessibilityQueue),
                  !Task.isCancelled, targetProcessIdentifier == pid else { return }
            targetFocusedElement = result
            targetFocusedElementProcessIdentifier = pid
        }
    }

    func pasteIntoRememberedAppIfPossible() {
        cancelPendingPaste()
        guard ensureAccessibilityPermission(), let targetApp = resolveTargetApplication() else { return }
        let changeCount = NSPasteboard.general.changeCount
        let pid = targetApp.processIdentifier
        let bundleIdentifier = targetApp.bundleIdentifier
        let capture = captureTask
        targetApp.activate(options: [])
        pasteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(140))
                await capture?.value
                try Task.checkCancellation()
                guard canPaste(into: targetApp, changeCount: changeCount) else { return }
                let remembered = targetFocusedElementProcessIdentifier == pid ? targetFocusedElement : nil
                let job = BackgroundJob(cancellableWork: { operation in
                    let search = AccessibilityFocusSearch(shouldContinue: { !operation.isCancelled })
                    _ = search.focusEditableElementIfNeeded(
                        processIdentifier: pid, bundleIdentifier: bundleIdentifier, remembered: remembered
                    )
                    return true
                })
                _ = try await job.value(on: accessibilityQueue)
                try await Task.sleep(for: .milliseconds(40))
                try Task.checkCancellation()
                guard canPaste(into: targetApp, changeCount: changeCount) else { return }
                postPasteShortcut(to: targetApp)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Accessibility focus lookup failed: %@", error.localizedDescription)
            }
        }
    }

    private func canPaste(into app: NSRunningApplication, changeCount: Int) -> Bool {
        !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            && NSPasteboard.general.changeCount == changeCount
    }

    private func resolveTargetApplication() -> NSRunningApplication? {
        let selfBundleID = Bundle.main.bundleIdentifier

        if let pid = targetProcessIdentifier,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           app.bundleIdentifier != selfBundleID {
            return app
        }

        if let bundleID = targetBundleIdentifier {
            let matched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })
            if let matched, matched.bundleIdentifier != selfBundleID {
                return matched
            }
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != selfBundleID {
            return frontmost
        }

        return NSWorkspace.shared.runningApplications.first(where: { app in
            app.activationPolicy == .regular
            && !app.isTerminated
            && app.bundleIdentifier != selfBundleID
        })
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        if !UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey) {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
        }
        return false
    }

    private func postPasteShortcut(to app: NSRunningApplication) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(app.processIdentifier)
        keyUp.postToPid(app.processIdentifier)
    }
}

nonisolated private struct RememberedAXElement: @unchecked Sendable {
    let element: AXUIElement
}

nonisolated private struct AXNodeKey: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

nonisolated private final class AccessibilityFocusSearch {
    private let shouldContinue: @Sendable () -> Bool
    private let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
    private var remainingNodes = 160
    private var editableVisited = Set<AXNodeKey>()
    private var roleVisited = Set<AXNodeKey>()
    private var roleSearchNodes = 48

    init(shouldContinue: @escaping @Sendable () -> Bool) {
        self.shouldContinue = shouldContinue
    }

    private var canContinue: Bool { shouldContinue() && ContinuousClock.now < deadline }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard canContinue else { return false }
        // 单次 IPC 超时也必须落在总时限内，失去响应的目标应用不会卡住 PasteHub。
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        AXUIElementSetMessagingTimeout(element, Float(min(0.04, max(0.001, seconds))))
        return true
    }

    func captureFocusedElement(processIdentifier: pid_t) -> RememberedAXElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let focused = copyElementValue(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        return RememberedAXElement(element: deepestFocusedElement(startingFrom: focused))
    }

    private let maxSearchDepth = 8
    private let maxChildrenPerNode = 80
    private let searchFieldRole = "AXSearchField"
    private let webAreaRole = "AXWebArea"
    private let editableAttribute = "AXEditable"
    private let traversalAttributes: [CFString] = [
        kAXContentsAttribute as CFString,
        kAXVisibleChildrenAttribute as CFString,
        kAXChildrenAttribute as CFString
    ]
    private let browserBundlePrefixes: [String] = ([
        [99, 111, 109, 46, 97, 112, 112, 108, 101, 46, 83, 97, 102, 97, 114, 105],
        [111, 114, 103, 46, 109, 111, 122, 105, 108, 108, 97, 46, 102, 105, 114, 101, 102, 111, 120],
        [99, 111, 109, 46, 103, 111, 111, 103, 108, 101, 46, 67, 104, 114, 111, 109, 101],
        [99, 111, 109, 46, 98, 114, 97, 118, 101, 46, 66, 114, 111, 119, 115, 101, 114],
        [99, 111, 109, 46, 109, 105, 99, 114, 111, 115, 111, 102, 116, 46, 101, 100, 103, 101, 109, 97, 99],
        [99, 111, 109, 46, 111, 112, 101, 114, 97, 115, 111, 102, 116, 119, 97, 114, 101, 46, 79, 112, 101, 114, 97],
        [99, 111, 109, 46, 118, 105, 118, 97, 108, 100, 105, 46, 86, 105, 118, 97, 108, 100, 105],
        [99, 111, 109, 112, 97, 110, 121, 46, 116, 104, 101, 98, 114, 111, 119, 115, 101, 114, 46, 66, 114, 111, 119, 115, 101, 114]
    ] as [[UInt8]]).map { String(decoding: $0, as: UTF8.self) }

    func focusEditableElementIfNeeded(
        processIdentifier: pid_t, bundleIdentifier: String?, remembered: RememberedAXElement?
    ) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        let skipDeepTraversal = isBrowserApp(bundleIdentifier)

        if let rememberedFocusedElement = remembered?.element {
            if isEditableElement(rememberedFocusedElement) {
                focus(element: rememberedFocusedElement)
                return rememberedFocusedElement
            }

            if !skipDeepTraversal,
               let found = findEditableElement(in: rememberedFocusedElement, depth: 0) {
                focus(element: found)
                return found
            }
        }

        if let focusedElement = copyElementValue(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString) {
            let deepestFocused = deepestFocusedElement(startingFrom: focusedElement)
            if isEditableElement(deepestFocused) {
                focus(element: deepestFocused)
                return deepestFocused
            }

            if !skipDeepTraversal,
               let found = findEditableElement(in: deepestFocused, depth: 0) {
                focus(element: found)
                return found
            }
        }

        if skipDeepTraversal {
            return nil
        }

        if let focusedWindow = copyElementValue(from: appElement, attribute: kAXFocusedWindowAttribute as CFString),
           let found = findEditableElementPreferringWebArea(in: focusedWindow) {
            focus(element: found)
            return found
        }

        if let mainWindow = copyElementValue(from: appElement, attribute: kAXMainWindowAttribute as CFString),
           let found = findEditableElementPreferringWebArea(in: mainWindow) {
            focus(element: found)
            return found
        }

        if let found = findEditableElement(in: appElement, depth: 0) {
            focus(element: found)
            return found
        }

        return nil
    }

    private func deepestFocusedElement(startingFrom element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<maxSearchDepth {
            guard let next = copyElementValue(from: current, attribute: kAXFocusedUIElementAttribute as CFString) else {
                break
            }
            if CFEqual(next, current) {
                break
            }
            current = next
        }
        return current
    }

    private func findEditableElement(in root: AXUIElement, depth: Int) -> AXUIElement? {
        guard canContinue, depth <= maxSearchDepth, remainingNodes > 0,
              editableVisited.insert(AXNodeKey(element: root)).inserted else { return nil }
        remainingNodes -= 1
        if isEditableElement(root) {
            return root
        }

        for attribute in traversalAttributes {
            let children = copyElementArray(from: root, attribute: attribute)
            for child in children {
                if let found = findEditableElement(in: child, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    private func findEditableElementPreferringWebArea(in root: AXUIElement) -> AXUIElement? {
        if let webArea = findElement(withRole: webAreaRole, in: root, depth: 0),
           let found = findEditableElement(in: webArea, depth: 0) {
            return found
        }
        return findEditableElement(in: root, depth: 0)
    }

    private func findElement(withRole role: String, in root: AXUIElement, depth: Int) -> AXUIElement? {
        guard canContinue, depth <= maxSearchDepth, remainingNodes > 0, roleSearchNodes > 0,
              roleVisited.insert(AXNodeKey(element: root)).inserted else { return nil }
        remainingNodes -= 1
        roleSearchNodes -= 1

        if copyStringValue(from: root, attribute: kAXRoleAttribute as CFString) == role {
            return root
        }

        for attribute in traversalAttributes {
            let children = copyElementArray(from: root, attribute: attribute)
            for child in children {
                if let found = findElement(withRole: role, in: child, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    private func isEditableElement(_ element: AXUIElement) -> Bool {
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            searchFieldRole
        ]

        if let role = copyStringValue(from: element, attribute: kAXRoleAttribute as CFString),
           textRoles.contains(role) {
            return true
        }

        if let editable = copyBoolValue(from: element, attribute: editableAttribute as CFString), editable {
            return true
        }

        guard prepare(element) else { return false }
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        return result == .success && isSettable.boolValue
    }

    private func focus(element: AXUIElement) {
        guard prepare(element) else { return }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        if result != .success, prepare(element) {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    private func isBrowserApp(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) })
    }

    private func copyElementValue(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyElementArray(from element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard prepare(element) else { return [] }
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(element, attribute, 0, maxChildrenPerNode, &values)
        guard result == .success, let values = values as? [AXUIElement] else { return [] }
        return values
    }

    private func copyStringValue(from element: AXUIElement, attribute: CFString) -> String? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copyBoolValue(from element: AXUIElement, attribute: CFString) -> Bool? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? Bool
    }

}
