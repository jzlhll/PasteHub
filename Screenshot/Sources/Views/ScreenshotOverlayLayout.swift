import CoreGraphics

nonisolated enum ScreenshotOverlayLayout {
    static func accessoryFrame(around selection: CGRect, within bounds: CGRect, size: CGSize,
                               sideSize: CGSize? = nil, topX: CGFloat, avoiding obstacles: [CGRect])
        -> (frame: CGRect, isVertical: Bool)? {
        let visible = bounds.insetBy(dx: 5, dy: 5)
        let gap: CGFloat = 8
        let side = sideSize ?? size
        let top = CGRect(x: visible.minX, y: visible.minY, width: visible.width,
                         height: selection.minY - gap - visible.minY)
        let left = CGRect(x: visible.minX, y: visible.minY, width: selection.minX - gap - visible.minX,
                          height: visible.height)
        let right = CGRect(x: selection.maxX + gap, y: visible.minY,
                           width: visible.maxX - selection.maxX - gap, height: visible.height)
        let bottom = CGRect(x: visible.minX, y: selection.maxY + gap, width: visible.width,
                            height: visible.maxY - selection.maxY - gap)
        let placements = [
            (top, size, CGPoint(x: topX, y: selection.minY - gap - size.height), false),
            (left, side, CGPoint(x: selection.minX - gap - side.width, y: selection.minY), sideSize != nil),
            (right, side, CGPoint(x: selection.maxX + gap, y: selection.minY), sideSize != nil),
            (bottom, size, CGPoint(x: selection.minX, y: selection.maxY + gap), false),
        ]
        for (area, controlSize, origin, isVertical) in placements {
            if let frame = closestFrame(in: area, size: controlSize, to: origin, avoiding: obstacles) {
                return (frame, isVertical)
            }
        }

        let inside = selection.intersection(visible).insetBy(dx: gap, dy: gap)
        for area in [inside, visible] {
            let anchor = CGPoint(x: topX, y: inside.minY.isFinite ? inside.minY : visible.minY)
            if let frame = closestFrame(in: area, size: size, to: anchor, avoiding: obstacles) {
                return (frame, false)
            }
            if let sideSize, let frame = closestFrame(in: area, size: sideSize, to: anchor, avoiding: obstacles) {
                return (frame, true)
            }
        }
        return nil
    }

    private static func closestFrame(in area: CGRect, size: CGSize, to origin: CGPoint,
                                     avoiding obstacles: [CGRect]) -> CGRect? {
        guard area.size.width >= size.width, area.size.height >= size.height else { return nil }
        return availableAreas(in: area, avoiding: obstacles)
            .filter { $0.width >= size.width && $0.height >= size.height }
            .map { available in
                CGRect(x: min(max(available.minX, origin.x.rounded()), available.maxX - size.width),
                       y: min(max(available.minY, origin.y.rounded()), available.maxY - size.height),
                       width: size.width, height: size.height)
            }
            .min {
                hypot($0.minX - origin.x, $0.minY - origin.y) < hypot($1.minX - origin.x, $1.minY - origin.y)
            }
    }

    static func availableAreas(in area: CGRect, avoiding obstacles: [CGRect]) -> [CGRect] {
        guard area.size.width > 0, area.size.height > 0 else { return [] }
        return obstacles.reduce([area]) { available, obstacle in
            available.flatMap { space in
                let overlap = space.intersection(obstacle.insetBy(dx: -8, dy: -8))
                guard !overlap.isEmpty else { return [space] }
                return [
                    CGRect(x: space.minX, y: space.minY, width: overlap.minX - space.minX, height: space.height),
                    CGRect(x: overlap.maxX, y: space.minY, width: space.maxX - overlap.maxX, height: space.height),
                    CGRect(x: space.minX, y: space.minY, width: space.width, height: overlap.minY - space.minY),
                    CGRect(x: space.minX, y: overlap.maxY, width: space.width, height: space.maxY - overlap.maxY),
                ].filter { !$0.isEmpty }
            }
        }
    }
}
