import AppKit
import SwiftUI

// 在冻结屏幕上完成取色、选区调整和标注，工具栏与蒙层不进入最终图片。
@MainActor
final class ScreenshotOverlayView: NSView {
    let editor = ScreenshotEditorState()
    private(set) var selection: CGRect?
    var onActivate: (() -> Void)?
    var onSelect: (() -> Void)?

    private let image: CGImage
    private let mosaic: CGImage
    private let bitmap: NSBitmapImageRep
    private var annotations: [ScreenshotAnnotation] = []
    private var pendingAnnotation: ScreenshotAnnotation?
    private var pendingSelection: CGRect?
    private let minimumSelectionPixels: CGFloat = 10
    private var toolbar: NSHostingView<ScreenshotToolbar>!
    private var tracking: NSTrackingArea?
    private var pointer = CGPoint.zero
    private var isRGB = false
    private var shiftDown = NSEvent.modifierFlags.contains(.shift)
    private var dragStart = CGPoint.zero
    private var originalSelection = CGRect.zero
    private var dragMode: DragMode?
    private enum DragMode: Equatable { case select, draw, move, resize(Int) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, image: CGImage) {
        self.image = image
        self.mosaic = ScreenshotRaster.pixelated(image, canvasSize: frame.size) ?? image
        self.bitmap = NSBitmapImageRep(cgImage: image)
        super.init(frame: frame)
        toolbar = NSHostingView(rootView: ScreenshotToolbar(state: editor))
        toolbar.isHidden = true
        addSubview(toolbar)
        editor.onChange = { [weak self] in
            self?.updateToolbar()
            self?.updatePointerCursor()
            self?.needsDisplay = true
        }
        editor.onUndo = { [weak self] in self?.undoAnnotation() }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            pointer = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: selection == nil || editor.tool != nil ? .crosshair : .arrow)
    }

    override func cursorUpdate(with event: NSEvent) { updatePointerCursor() }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        onActivate?()
        updatePointerCursor()
        needsDisplay = true
    }

    private func updatePointerCursor() {
        if !toolbar.isHidden, toolbar.frame.contains(pointer) {
            NSCursor.arrow.set()
        } else if selection == nil || editor.tool != nil || handleIndex(at: pointer) != nil {
            NSCursor.crosshair.set()
        } else if selection?.contains(pointer) == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    func handleModifiers(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.shift)
        if pressed && !shiftDown && selection == nil { isRGB.toggle(); needsDisplay = true }
        shiftDown = pressed
    }

    private var pixelPoint: CGPoint {
        CGPoint(x: min(CGFloat(image.width - 1), max(0, floor(pointer.x * CGFloat(image.width) / bounds.width))),
                y: min(CGFloat(image.height - 1), max(0, floor(pointer.y * CGFloat(image.height) / bounds.height))))
    }

    var colorValue: String? {
        let pixel = pixelPoint
        guard let color = bitmap.colorAt(x: Int(pixel.x), y: Int(pixel.y))?.usingColorSpace(.sRGB) else { return nil }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return isRGB ? "(\(red), \(green), \(blue))" : String(format: "#%02x%02x%02x", red, green, blue)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 禁用按钮及工具栏空白处的事件也可能向上传递，不能据此开始框选。
        guard bounds.contains(point), toolbar.isHidden || !toolbar.frame.contains(point) else { return }
        pointer = bounded(point)
        dragStart = pointer
        onActivate?()
        window?.makeFirstResponder(self)
        if event.clickCount == 2, editor.tool == nil, let selection, selection.contains(pointer) {
            editor.onCopy?()
            return
        }
        if let index = handleIndex(at: pointer), let selection {
            originalSelection = selection
            dragMode = .resize(index)
        } else if let selection, selection.contains(pointer) {
            if let tool = editor.tool {
                dragMode = .draw
                pendingAnnotation = ScreenshotAnnotation(tool: tool, color: editor.color,
                                                         lineWidth: editor.activeLineWidth, points: [pointer])
            } else {
                dragMode = .move
                originalSelection = selection
                NSCursor.closedHand.set()
            }
        } else {
            // 新选区通过最小尺寸校验并松开鼠标后，才替换原选区与标注。
            pendingSelection = nil
            dragMode = .select
        }
        if dragMode != .select { toolbar.isHidden = true }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = bounded(convert(event.locationInWindow, from: nil))
        guard let dragMode else { return }
        switch dragMode {
        case .select:
            let candidate = rect(from: dragStart, to: pointer)
            pendingSelection = isValidSelection(candidate) ? candidate : nil
            toolbar.isHidden = pendingSelection != nil || selection == nil
        case .draw:
            guard let selection else { return }
            let point = CGPoint(x: min(selection.maxX, max(selection.minX, pointer.x)),
                                y: min(selection.maxY, max(selection.minY, pointer.y)))
            if pendingAnnotation?.tool.isFreehand == true {
                if pendingAnnotation?.points.last != point { pendingAnnotation?.points.append(point) }
            } else {
                pendingAnnotation?.points = [dragStart, point]
            }
        case .move:
            let x = min(bounds.width - originalSelection.width, max(0, originalSelection.minX + pointer.x - dragStart.x))
            let y = min(bounds.height - originalSelection.height, max(0, originalSelection.minY + pointer.y - dragStart.y))
            let next = CGRect(origin: CGPoint(x: x, y: y), size: originalSelection.size)
            // 标注坐标跟随选区移动，拖动中使用相邻位置的增量。
            let dx = next.minX - (selection?.minX ?? next.minX)
            let dy = next.minY - (selection?.minY ?? next.minY)
            for index in annotations.indices {
                annotations[index].points = annotations[index].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
            selection = next
        case .resize(let index):
            var left = originalSelection.minX, right = originalSelection.maxX
            var top = originalSelection.minY, bottom = originalSelection.maxY
            if [0, 6, 7].contains(index) { left = pointer.x }
            if [2, 3, 4].contains(index) { right = pointer.x }
            if [0, 1, 2].contains(index) { top = pointer.y }
            if [4, 5, 6].contains(index) { bottom = pointer.y }
            let candidate = rect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom))
            if isValidSelection(candidate) { selection = candidate }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragMode else { return }
        mouseDragged(with: event)
        if dragMode == .select, let candidate = pendingSelection {
            resetSelection()
            selection = candidate
            onSelect?()
        } else if let pendingAnnotation {
            annotations.append(pendingAnnotation)
            self.pendingAnnotation = nil
        }
        pendingSelection = nil
        self.dragMode = nil
        editor.canUndo = !annotations.isEmpty
        updateToolbar()
        updatePointerCursor()
        needsDisplay = true
    }

    func resetSelection() {
        selection = nil
        annotations.removeAll()
        pendingAnnotation = nil
        pendingSelection = nil
        dragMode = nil
        editor.tool = nil
        editor.canUndo = false
        toolbar.isHidden = true
        needsDisplay = true
    }

    func undoAnnotation() {
        guard !annotations.isEmpty, dragMode == nil else { return }
        annotations.removeLast()
        editor.canUndo = !annotations.isEmpty
        needsDisplay = true
    }

    func exportImage() -> CGImage? {
        guard let selection, isValidSelection(selection) else { return nil }
        return ScreenshotRaster.export(image: image, mosaic: mosaic, canvasSize: bounds.size,
                                       selection: selection, annotations: annotations)
    }

    private func isValidSelection(_ rect: CGRect) -> Bool {
        let width = floor(rect.width * CGFloat(image.width) / bounds.width)
        let height = floor(rect.height * CGFloat(image.height) / bounds.height)
        return width > minimumSelectionPixels && height > minimumSelectionPixels
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(bounds.width, max(0, point.x)), y: min(bounds.height, max(0, point.y)))
    }

    private func rect(from first: CGPoint, to last: CGPoint) -> CGRect {
        CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
               width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    private var handles: [CGPoint] {
        guard let r = selection else { return [] }
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handleIndex(at point: CGPoint) -> Int? {
        handles.firstIndex { abs($0.x - point.x) <= 6 && abs($0.y - point.y) <= 6 }
    }

    private func updateToolbar() {
        guard let selection, dragMode == nil else { toolbar.isHidden = true; return }
        // 预留二级面板高度，底部空间不足时整体放到选区上方或屏幕内。
        let size = CGSize(width: 484, height: editor.tool != nil ? 124 : 60)
        let x = min(max(4, selection.maxX - size.width), max(4, bounds.width - size.width - 4))
        var y = selection.maxY + 10
        if y + size.height > bounds.height - 4 { y = selection.minY - size.height - 10 }
        y = min(max(4, y), max(4, bounds.height - size.height - 4))
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        toolbar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let displayedSelection = pendingSelection ?? selection
        ScreenshotRaster.draw(image, in: bounds, context: context)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        context.addRect(bounds)
        if let displayedSelection { context.addRect(displayedSelection) }
        context.fillPath(using: .evenOdd)
        context.restoreGState()
        if let selection = displayedSelection {
            if pendingSelection == nil {
                context.saveGState()
                context.clip(to: selection)
                for annotation in annotations { annotation.draw(in: context, mosaic: mosaic, canvasSize: bounds.size) }
                pendingAnnotation?.draw(in: context, mosaic: mosaic, canvasSize: bounds.size)
                context.restoreGState()
            }
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1)
            context.stroke(selection)
            if pendingSelection == nil, dragMode == nil || dragMode == .select {
                for point in handles {
                    let handle = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(handle)
                    context.stroke(handle)
                }
            }
            let width = Int((selection.width * CGFloat(image.width) / bounds.width).rounded())
            let height = Int((selection.height * CGFloat(image.height) / bounds.height).rounded())
            drawLabel("\(width) × \(height)", at: CGPoint(x: selection.minX + 5, y: max(5, selection.minY - 26)))
            if pendingSelection == nil, editor.tool?.isBrush == true, selection.contains(pointer),
               toolbar.isHidden || !toolbar.frame.contains(pointer),
               dragMode == .draw || (dragMode == nil && handleIndex(at: pointer) == nil) {
                let diameter = editor.activeLineWidth
                let brush = CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2,
                                   width: diameter, height: diameter)
                context.saveGState()
                context.clip(to: selection)
                context.setLineWidth(3)
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
                context.strokeEllipse(in: brush)
                context.setLineWidth(1)
                context.setStrokeColor(NSColor.white.cgColor)
                context.strokeEllipse(in: brush)
                context.restoreGState()
            }
        } else if bounds.contains(pointer), window?.frame.contains(NSEvent.mouseLocation) == true {
            drawMagnifier(in: context)
        }
    }

    private func drawMagnifier(in context: CGContext) {
        let previewSize: CGFloat = 180
        let width = previewSize + 24, height = previewSize + 92
        var x = pointer.x - width - 20
        if x < 8 { x = pointer.x + 20 }
        x = min(max(8, x), max(8, bounds.width - width - 8))
        var y = pointer.y + 20
        if y + height > bounds.height - 8 { y = pointer.y - height - 20 }
        y = min(max(8, y), max(8, bounds.height - height - 8))
        let card = CGRect(x: x, y: y, width: width, height: height)
        context.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        context.addPath(CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        let target = CGRect(x: x + 12, y: y + 12, width: previewSize, height: previewSize)
        let magnification: CGFloat = 3
        let pixel = pixelPoint
        let sampleRadius = ceil(target.width / (2 * magnification))
        let sampleSize = sampleRadius * 2 + 1
        let sampleRect = CGRect(x: pixel.x - sampleRadius, y: pixel.y - sampleRadius,
                                width: sampleSize, height: sampleSize)
        let clipped = sampleRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(NSColor.darkGray.cgColor)
        context.fill(target)
        if let sample = image.cropping(to: clipped) {
            let destination = CGRect(x: target.midX - sampleSize * magnification / 2
                                         + (clipped.minX - sampleRect.minX) * magnification,
                                     y: target.midY - sampleSize * magnification / 2
                                         + (clipped.minY - sampleRect.minY) * magnification,
                                     width: clipped.width * magnification, height: clipped.height * magnification)
            context.saveGState()
            context.clip(to: target)
            context.interpolationQuality = .none
            ScreenshotRaster.draw(sample, in: destination, context: context)
            context.restoreGState()
        }
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: target.midX, y: target.minY))
        context.addLine(to: CGPoint(x: target.midX, y: target.maxY))
        context.move(to: CGPoint(x: target.minX, y: target.midY))
        context.addLine(to: CGPoint(x: target.maxX, y: target.midY))
        context.strokePath()
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.stroke(CGRect(x: target.midX - magnification / 2, y: target.midY - magnification / 2,
                              width: magnification, height: magnification))
        drawText("X: \(Int(pixel.x))  Y: \(Int(pixel.y))", at: CGPoint(x: x + 12, y: target.maxY + 9), size: 12)
        drawText(colorValue ?? "无法取色", at: CGPoint(x: x + 12, y: target.maxY + 30), size: 14)
        drawText("Shift 切换 · ⌘C 复制", at: CGPoint(x: x + 12, y: target.maxY + 57), size: 10)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 3, width: size.width + 8, height: 22),
                     xRadius: 4, yRadius: 4).fill()
        drawText(text, at: point, size: 12)
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white
        ])
    }
}
