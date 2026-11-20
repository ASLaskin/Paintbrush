//
//  SWJNTransformBox.swift
//  Paintbrush
//
//  A placed object shown in a box that can be moved, scaled (corner squares,
//  around the center) and rotated (square above the box, Shift snaps to 15
//  degrees). Subclasses draw the content; text and images both use it.
//

import Cocoa

class SWJNTransformBox: SWJNPlacedObject {
    struct Geometry {
        var center: NSPoint
        var scale: CGFloat
        var angle: CGFloat
    }

    /// Unscaled content size in canvas pixels.
    let contentSize: NSSize
    private(set) var geometry: Geometry

    /// Distance from the top edge to the rotate handle, in screen points.
    private static let rotateStem: CGFloat = 22
    private static let minimumScale: CGFloat = 0.02

    init(contentSize: NSSize, topLeft: NSPoint, scale: CGFloat = 1) {
        self.contentSize = contentSize
        geometry = Geometry(center: NSPoint(x: topLeft.x + contentSize.width * scale / 2,
                                            y: topLeft.y + contentSize.height * scale / 2),
                            scale: scale, angle: 0)
    }

    /// Draws the content upright and unscaled in a y up space, with its
    /// bounds at (-width / 2, -height / 2, width, height).
    func drawContent() {}

    /// Axis aligned bounds of the transformed box, in canvas coordinates.
    var bounds: NSRect {
        let points = corners
        let xs = points.map(\.x), ys = points.map(\.y)
        return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    var isUntransformed: Bool { geometry.scale == 1 && geometry.angle == 0 }

    /// True while a handle is being dragged, so drawing can favor speed.
    var isInteracting = false

    // Box corners in view coordinates: top left, top right, bottom right, bottom left
    private var corners: [NSPoint] {
        let halfWidth = contentSize.width * geometry.scale / 2
        let halfHeight = contentSize.height * geometry.scale / 2
        return [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]
            .map { geometry.center + NSPoint(x: $0.0, y: $0.1).rotated(by: geometry.angle) }
    }

    private func topMiddle() -> NSPoint {
        geometry.center + NSPoint(x: 0, y: -contentSize.height * geometry.scale / 2).rotated(by: geometry.angle)
    }

    private func rotateHandle(scale: CGFloat) -> NSPoint {
        topMiddle() + NSPoint(x: 0, y: -Self.rotateStem / scale).rotated(by: geometry.angle)
    }

    // MARK: SWJNPlacedObject

    func render() {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        // Bitmaps are drawn into in view coordinates (y down), so flip locally
        // to keep the content upright, then draw centered on the origin.
        let transform = NSAffineTransform()
        transform.translateX(by: geometry.center.x, yBy: geometry.center.y)
        transform.rotate(byRadians: geometry.angle)
        transform.scaleX(by: geometry.scale, yBy: -geometry.scale)
        transform.concat()
        drawContent()

        context.restoreGraphicsState()
    }

    func drawHandles(scale: CGFloat) {
        let box = NSBezierPath()
        let points = corners
        box.move(to: points[0])
        points.dropFirst().forEach { box.line(to: $0) }
        box.close()
        SWJNHandleStyle.outline(box, scale: scale)

        let stem = NSBezierPath()
        stem.move(to: topMiddle())
        stem.line(to: rotateHandle(scale: scale))
        SWJNHandleStyle.outline(stem, scale: scale)

        points.forEach { SWJNHandleStyle.drawSquare(at: $0, scale: scale) }
        SWJNHandleStyle.drawSquare(at: rotateHandle(scale: scale), scale: scale)
    }

    func hitTest(_ point: NSPoint, scale: CGFloat) -> SWJNPlacementHandle? {
        if SWJNHandleStyle.hits(point, handleAt: rotateHandle(scale: scale), scale: scale) { return .rotate }
        for (index, corner) in corners.enumerated() where SWJNHandleStyle.hits(point, handleAt: corner, scale: scale) {
            return .corner(index)
        }

        // Inside the (rotated) box
        let local = (point - geometry.center).rotated(by: -geometry.angle)
        let slop = SWJNHandleStyle.hitSlop / scale
        if abs(local.x) <= contentSize.width * geometry.scale / 2 + slop,
           abs(local.y) <= contentSize.height * geometry.scale / 2 + slop {
            return .body
        }
        return nil
    }

    func snapshot() -> Any { geometry }

    func drag(_ handle: SWJNPlacementHandle, from start: NSPoint, to point: NSPoint, original: Any, snap: Bool) {
        guard let original = original as? Geometry else { return }
        switch handle {
        case .body:
            geometry.center = original.center + (point - start)

        case .corner:
            // Scale around the center, by how far the corner moved from it
            let startDistance = (start - original.center).length
            guard startDistance > 0 else { return }
            geometry.scale = max(Self.minimumScale, original.scale * (point - original.center).length / startDistance)

        case .rotate:
            // The handle sits straight above the center, which is angle -90 degrees
            let delta = point - original.center
            let angle = atan2(delta.y, delta.x) + .pi / 2
            geometry.angle = snap ? SWJNSnapAngle(angle) : angle

        case .endpoint:
            break
        }
    }

    /// Moves the box by whole pixels (arrow keys).
    func nudge(by offset: NSPoint) {
        geometry.center = geometry.center + offset
    }
}
