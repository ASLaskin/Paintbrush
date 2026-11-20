//
//  SWJNLineTool.swift
//  Paintbrush
//
//  Created by Jarrod Norwell on 17/8/2026.
//
//  Drag to draw a line. Once released it stays editable: drag an end square
//  to resize or rotate it, drag the line itself to move it. Shift snaps to
//  45 degree angles, both while drawing and while dragging an end.
//

import Foundation

@objcMembers class SWJNLineTool : SWJNPlacementTool {
    private var color: NSColor = .black

    override func creationEvent(_ mouseEvent: SWJNMouseEvent, at point: CGPoint,
                                main: NSBitmapImageRep, buffer: NSBitmapImageRep) {
        if mouseEvent == .down {
            color = flags.contains(.option) ? backgroundColor : foregroundColor
        }

        let line = SWJNPlacedLine(start: savedPoint,
                                  end: SWJNPlacedLine.snapped(savedPoint, point, enabled: flags.contains(.shift)),
                                  width: lineWidth, color: color)

        if mouseEvent == .up {
            // A click without a drag leaves nothing to edit
            if line.start == line.end {
                SWImageTools.clearImage(buffer)
                return
            }
            place(line)
        } else {
            SWImageTools.clearImage(buffer)
            SWLockFocus(buffer)
            line.render()
            SWUnlockFocus(buffer)
        }
    }

    nonisolated override var description: String {
        "Line"
    }
}

final class SWJNPlacedLine: SWJNPlacedObject {
    var start: NSPoint
    var end: NSPoint
    let width: CGFloat
    let color: NSColor
    var isInteracting = false

    init(start: NSPoint, end: NSPoint, width: CGFloat, color: NSColor) {
        self.start = start
        self.end = end
        self.width = width
        self.color = color
    }

    /// `to` moved so the line from `from` sits on a multiple of 45 degrees.
    static func snapped(_ from: NSPoint, _ to: NSPoint, enabled: Bool) -> NSPoint {
        guard enabled else { return to }
        let delta = to - from
        let angle = SWJNSnapAngle(atan2(delta.y, delta.x), step: .pi / 4)
        let length = delta.length
        return NSPoint(x: (from.x + cos(angle) * length).rounded(), y: (from.y + sin(angle) * length).rounded())
    }

    func render() {
        NSGraphicsContext.current?.shouldAntialias = false
        color.setStroke()

        // Thin lines sit on pixel centers so they stay one pixel wide
        let offset: CGFloat = width <= 1 ? 0.5 : 0
        let path = NSBezierPath()
        path.lineWidth = width
        path.move(to: NSPoint(x: start.x + offset, y: start.y + offset))
        path.line(to: NSPoint(x: end.x + offset, y: end.y + offset))
        path.stroke()
    }

    func drawHandles(scale: CGFloat) {
        SWJNHandleStyle.drawSquare(at: start, scale: scale)
        SWJNHandleStyle.drawSquare(at: end, scale: scale)
    }

    func hitTest(_ point: NSPoint, scale: CGFloat) -> SWJNPlacementHandle? {
        if SWJNHandleStyle.hits(point, handleAt: start, scale: scale) { return .endpoint(0) }
        if SWJNHandleStyle.hits(point, handleAt: end, scale: scale) { return .endpoint(1) }

        // Grab the body anywhere within the stroke, with a little slop for thin lines
        let reach = max(width / 2, 0) + SWJNHandleStyle.hitSlop / scale
        return distanceToSegment(point) <= reach ? .body : nil
    }

    func snapshot() -> Any { (start, end) }

    func drag(_ handle: SWJNPlacementHandle, from dragStart: NSPoint, to point: NSPoint, original: Any, snap: Bool) {
        guard let (origStart, origEnd) = original as? (NSPoint, NSPoint) else { return }
        let delta = point - dragStart
        switch handle {
        case .endpoint(0):
            start = Self.snapped(origEnd, origStart + delta, enabled: snap)
        case .endpoint(_):
            end = Self.snapped(origStart, origEnd + delta, enabled: snap)
        default:
            start = origStart + delta
            end = origEnd + delta
        }
    }

    func nudge(by offset: NSPoint) {
        start = start + offset
        end = end + offset
    }

    private func distanceToSegment(_ p: NSPoint) -> CGFloat {
        let segment = end - start
        let lengthSquared = segment.x * segment.x + segment.y * segment.y
        guard lengthSquared > 0 else { return (p - start).length }
        let t = max(0, min(1, ((p.x - start.x) * segment.x + (p.y - start.y) * segment.y) / lengthSquared))
        return (p - NSPoint(x: start.x + t * segment.x, y: start.y + t * segment.y)).length
    }
}
