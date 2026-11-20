//
//  SWJNTextTool.swift
//  Paintbrush
//
//  Created by Jarrod Norwell on 17/8/2026.
//
//  Click to type text. Once entered it appears at the click point and stays
//  editable: drag it to move, drag a corner square to resize, drag the square
//  above it to rotate (Shift snaps to 15 degrees).
//

import Foundation

@objcMembers class SWJNTextTool : SWJNPlacementTool {
    /// Where the next entered text goes. Set only on the tool that was clicked,
    /// since every text tool hears the (global) text entered notification.
    private var pendingAnchor: NSPoint?

    override init(document: SWDocument, paintView: SWPaintView, toolbox: SWToolbox, toolboxController: SWToolboxController) {
        super.init(document: document, paintView: paintView, toolbox: toolbox, toolboxController: toolboxController)
        NotificationCenter.default.addObserver(self, selector: #selector(insertText(notification:)),
                                               name: .textEnteredNotificationName,
                                               object: nil)
    }

    override func creationEvent(_ mouseEvent: SWJNMouseEvent, at point: CGPoint,
                                main: NSBitmapImageRep, buffer: NSBitmapImageRep) {
        guard mouseEvent == .down else { return }
        pendingAnchor = NSPoint(x: floor(point.x), y: floor(point.y))
        NotificationCenter.default.post(name: .textNotificationName, object: foregroundColor)
    }

    @objc func insertText(notification: NSNotification) {
        guard let anchor = pendingAnchor,
              let attributedString = notification.object as? NSAttributedString,
              attributedString.length > 0 else {
            return
        }
        pendingAnchor = nil
        place(SWJNPlacedText(text: NSAttributedString(attributedString: attributedString), topLeft: anchor))
    }

    override func finalise() {
        pendingAnchor = nil
        super.finalise()
    }

    nonisolated override var description: String {
        "Text"
    }
}

final class SWJNPlacedText: SWJNPlacedObject {
    private struct Geometry {
        var center: NSPoint
        var scale: CGFloat
        var angle: CGFloat
    }

    private let text: NSAttributedString
    private let size: NSSize
    private var geometry: Geometry

    /// Distance from the top edge to the rotate handle, in screen points.
    private static let rotateStem: CGFloat = 22
    private static let minimumScale: CGFloat = 0.1

    init(text: NSAttributedString, topLeft: NSPoint) {
        self.text = text
        size = text.size()
        geometry = Geometry(center: NSPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2),
                            scale: 1, angle: 0)
    }

    // Box corners in view coordinates: top left, top right, bottom right, bottom left
    private var corners: [NSPoint] {
        let halfWidth = size.width * geometry.scale / 2
        let halfHeight = size.height * geometry.scale / 2
        return [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]
            .map { geometry.center + NSPoint(x: $0.0, y: $0.1).rotated(by: geometry.angle) }
    }

    private func topMiddle() -> NSPoint {
        geometry.center + NSPoint(x: 0, y: -size.height * geometry.scale / 2).rotated(by: geometry.angle)
    }

    private func rotateHandle(scale: CGFloat) -> NSPoint {
        let extra = NSPoint(x: 0, y: -Self.rotateStem / scale).rotated(by: geometry.angle)
        return topMiddle() + extra
    }

    func render() {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.shouldAntialias = true

        // Bitmaps are drawn into in view coordinates (y down), so flip locally
        // to keep glyphs upright, then draw centered on the origin.
        let transform = NSAffineTransform()
        transform.translateX(by: geometry.center.x, yBy: geometry.center.y)
        transform.rotate(byRadians: geometry.angle)
        transform.scaleX(by: geometry.scale, yBy: -geometry.scale)
        transform.concat()
        text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))

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
        if abs(local.x) <= size.width * geometry.scale / 2 + slop,
           abs(local.y) <= size.height * geometry.scale / 2 + slop {
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
}
