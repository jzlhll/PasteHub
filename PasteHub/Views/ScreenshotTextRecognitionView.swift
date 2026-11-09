import AppKit
import CoreImage

// 在截图旁展示可编辑的识别结果，仅模糊背后的冻结画面，保持文字和操作按钮清晰。
@MainActor
final class ScreenshotTextRecognitionView: NSView {
    let textView: NSTextView = ScreenshotRecognitionTextView()
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let blurredBackdrop: CGImage?

    override var isFlipped: Bool { true }

    init(frame: CGRect, text: String, backdrop: CGImage?) {
        if let backdrop {
            let input = CIImage(cgImage: backdrop)
            let scale = Double(backdrop.width) / Double(frame.width)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 14 * scale)
                .cropped(to: input.extent)
            blurredBackdrop = CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: input.extent)
        } else {
            blurredBackdrop = nil
        }
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor

        let title = NSTextField(labelWithString: "识别结果")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor

        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: frame.width - 28, height: .greatestFiniteMagnitude)
        textView.textContainerInset = CGSize(width: 8, height: 10)
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("识别结果，可编辑")
        scroll.documentView = textView

        let copy = NSButton(title: "复制", target: self, action: #selector(copyText))
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        let close = NSButton(title: "关闭", target: self, action: #selector(closeResult))
        close.bezelStyle = .rounded

        for view in [title, scroll, copy, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            copy.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            copy.widthAnchor.constraint(equalToConstant: 76),
            copy.heightAnchor.constraint(equalToConstant: 28),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            close.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 76),
            close.heightAnchor.constraint(equalTo: copy.heightAnchor)
        ])
        layoutSubtreeIfNeeded()
        textView.frame.size = scroll.contentSize
        textView.minSize = CGSize(width: 0, height: scroll.contentSize.height)
        textView.sizeToFit()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let blurredBackdrop, let context = NSGraphicsContext.current?.cgContext {
            ScreenshotRaster.draw(blurredBackdrop, in: bounds, context: context)
        }
        NSColor.white.withAlphaComponent(0.78).setFill()
        bounds.fill()
    }

    @objc private func copyText() { onCopy?(textView.string) }
    @objc private func closeResult() { onClose?() }

    static func preferredFrame(around selection: CGRect, within bounds: CGRect, avoiding toolbar: CGRect) -> CGRect {
        let visible = bounds.insetBy(dx: 12, dy: 12)
        let gap: CGFloat = 12
        let desired = CGSize(width: 360, height: 280)
        let minimum = CGSize(width: 240, height: 180)
        let outside = [
            CGRect(x: selection.maxX + gap, y: visible.minY,
                   width: visible.maxX - selection.maxX - gap, height: visible.height),
            CGRect(x: visible.minX, y: visible.minY,
                   width: selection.minX - gap - visible.minX, height: visible.height),
            CGRect(x: visible.minX, y: selection.maxY + gap,
                   width: visible.width, height: visible.maxY - selection.maxY - gap),
            CGRect(x: visible.minX, y: visible.minY,
                   width: visible.width, height: selection.minY - gap - visible.minY)
        ]
        var best: CGRect?
        // 先检查截图外的所有可用区域；工具栏占用的位置也不能遮挡结果框。
        for area in outside where area.width > 0 && area.height > 0 {
            for space in spaces(in: area, avoiding: toolbar.insetBy(dx: -8, dy: -8)) {
                guard space.width >= minimum.width, space.height >= minimum.height else { continue }
                let size = CGSize(width: min(desired.width, space.width), height: min(desired.height, space.height))
                let candidate = CGRect(x: min(max(selection.minX, space.minX), space.maxX - size.width),
                                       y: min(max(selection.minY, space.minY), space.maxY - size.height),
                                       width: size.width, height: size.height)
                if size == desired { return candidate.integral }
                if let current = best {
                    if candidate.width * candidate.height > current.width * current.height { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        if let best { return best.integral }

        let intersection = selection.intersection(visible)
        let inside = intersection.insetBy(dx: min(8, intersection.width / 4), dy: min(8, intersection.height / 4))
        let available = spaces(in: inside, avoiding: toolbar.insetBy(dx: -8, dy: -8))
            .filter { $0.width >= minimum.width && $0.height >= minimum.height }
            .max { $0.width * $0.height < $1.width * $1.height } ?? inside
        let size = CGSize(width: min(desired.width, available.width), height: min(desired.height, available.height))
        return CGRect(x: available.maxX - size.width, y: available.minY, width: size.width, height: size.height).integral
    }

    private static func spaces(in area: CGRect, avoiding obstacle: CGRect) -> [CGRect] {
        let overlap = area.intersection(obstacle)
        guard !overlap.isNull else { return [area] }
        return [
            CGRect(x: area.minX, y: area.minY, width: overlap.minX - area.minX, height: area.height),
            CGRect(x: overlap.maxX, y: area.minY, width: area.maxX - overlap.maxX, height: area.height),
            CGRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY),
            CGRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY)
        ]
    }
}

// 识别结果的编辑使用独立撤销栈，避免影响截图标注。
private final class ScreenshotRecognitionTextView: NSTextView {
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
}
