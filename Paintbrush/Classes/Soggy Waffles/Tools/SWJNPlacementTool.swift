//
//  SWJNPlacementTool.swift
//  Paintbrush
//
//  Tools whose result stays editable (move, resize, rotate) right after it is
//  placed. The object lives in the buffer image with handles drawn over it,
//  and is stamped into the main image ("committed") when the user clicks away,
//  presses Return or Escape, switches tools, or saves. Delete discards it.
//

import Cocoa

/// Something placed on the canvas that can still be edited. All geometry is in
/// paint view coordinates (y grows downward), which is also what tools draw
/// into the bitmaps with.
protocol SWJNPlacedObject: AnyObject {
    /// Draws the object into the current graphics context (a locked bitmap).
    func render()
    /// Draws selection handles into the paint view. `scale` is the zoom factor.
    func drawHandles(scale: CGFloat)
    /// The handle or body under `point`, if any.
    func hitTest(_ point: NSPoint, scale: CGFloat) -> SWJNPlacementHandle?
    /// Opaque copy of the geometry, taken when a drag starts.
    func snapshot() -> Any
    /// Set while a handle is dragged, so heavy objects can draw quickly.
    var isInteracting: Bool { get set }
    /// Applies a drag of `handle` that started at `start` (with geometry
    /// `original`) and is now at `point`.
    func drag(_ handle: SWJNPlacementHandle, from start: NSPoint, to point: NSPoint, original: Any, snap: Bool)
    /// Moves the object by `offset` (arrow keys).
    func nudge(by offset: NSPoint)
}

enum SWJNPlacementHandle: Equatable {
    case body
    case endpoint(Int)
    case corner(Int)
    case rotate
}

@objcMembers class SWJNPlacementTool: SWJNTool {
    private(set) var placed: SWJNPlacedObject?
    private var activeDrag: (handle: SWJNPlacementHandle, start: NSPoint, original: Any)?

    /// True while the current mouse press edits the placed object rather than
    /// creating something new.
    var isEditingPlaced: Bool { activeDrag != nil }

    // MARK: Subclass hooks

    /// Called on a mouse down that does not hit the placed object (after any
    /// previous object was committed).
    func creationEvent(_ mouseEvent: SWJNMouseEvent, at point: CGPoint,
                       main: NSBitmapImageRep, buffer: NSBitmapImageRep) {}

    // MARK: Event routing

    override func performDraw(from point: CGPoint,
                              on mainBitmap: NSBitmapImageRep, and bufferBitmap: NSBitmapImageRep,
                              for mouseEvent: SWJNMouseEvent) -> NSBezierPath? {
        mainBitmapRep = mainBitmap
        bufferBitmapRep = bufferBitmap
        redrawRect = paintView.bounds

        switch mouseEvent {
        case .down:
            if let placed, let handle = placed.hitTest(point, scale: paintView.viewScale()) {
                activeDrag = (handle, point, placed.snapshot())
                placed.isInteracting = true
                return nil
            }
            commit()
            creationEvent(.down, at: point, main: mainBitmap, buffer: bufferBitmap)

        case .dragged:
            if let drag = activeDrag, let placed {
                placed.drag(drag.handle, from: drag.start, to: point, original: drag.original,
                            snap: flags.contains(.shift))
                renderPlaced()
            } else {
                creationEvent(.dragged, at: point, main: mainBitmap, buffer: bufferBitmap)
            }

        case .up:
            if activeDrag != nil {
                activeDrag = nil
                placed?.isInteracting = false
                renderPlaced()
            } else {
                creationEvent(.up, at: point, main: mainBitmap, buffer: bufferBitmap)
            }

        case .moved:
            break
        }
        return nil
    }

    // MARK: Placement lifecycle

    /// Puts a new editable object on the canvas. Registers the undo step now,
    /// so Command Z removes the object even before it is committed. Pass
    /// `registerUndo: false` when the caller already registered it.
    func place(_ object: SWJNPlacedObject, registerUndo: Bool = true) {
        if registerUndo { document.handleUndo(withImageData: nil, frame: .zero) }
        placed = object
        renderPlaced()
    }

    /// Hands the tool the document's bitmaps for work that does not start with
    /// a mouse press (paste, select all).
    func attach(main: NSBitmapImageRep, buffer: NSBitmapImageRep) {
        mainBitmapRep = main
        bufferBitmapRep = buffer
    }

    /// Draws the placed object into the buffer image.
    func renderPlaced() {
        guard let buffer = bufferBitmapRep else { return }
        SWImageTools.clearImage(buffer)
        if let placed {
            SWLockFocus(buffer)
            placed.render()
            SWUnlockFocus(buffer)
        }
        paintView.needsDisplay = true
    }

    /// Stamps the placed object into the main image.
    func commit() {
        guard let placed, let main = mainBitmapRep else { return }
        self.placed = nil
        activeDrag = nil
        placed.isInteracting = false

        SWLockFocus(main)
        placed.render()
        SWUnlockFocus(main)

        if let buffer = bufferBitmapRep { SWImageTools.clearImage(buffer) }
        paintView.needsDisplay = true
    }

    /// Throws the placed object away.
    func discard() {
        placed = nil
        activeDrag = nil
        if let buffer = bufferBitmapRep { SWImageTools.clearImage(buffer) }
        paintView.needsDisplay = true
    }

    override func drawOverlay(scale: CGFloat) {
        placed?.drawHandles(scale: scale)
    }

    override func deleteKey() {
        discard()
    }

    override func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let placed, activeDrag == nil else { return false }
        placed.nudge(by: NSPoint(x: dx, y: dy))
        renderPlaced()
        return true
    }

    override func finalise() {
        super.finalise()
        commit()
    }
}

// MARK: Handle drawing

enum SWJNHandleStyle {
    static let size: CGFloat = 8
    static let hitSlop: CGFloat = 5

    static func drawSquare(at point: NSPoint, scale: CGFloat) {
        let side = size / scale
        let rect = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1 / scale
        NSColor.white.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    static func hits(_ point: NSPoint, handleAt handle: NSPoint, scale: CGFloat) -> Bool {
        let reach = (size / 2 + hitSlop) / scale
        return abs(point.x - handle.x) <= reach && abs(point.y - handle.y) <= reach
    }

    static func outline(_ path: NSBezierPath, scale: CGFloat) {
        path.lineWidth = 1 / scale
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: Geometry helpers

extension NSPoint {
    static func + (a: NSPoint, b: NSPoint) -> NSPoint { NSPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: NSPoint, b: NSPoint) -> NSPoint { NSPoint(x: a.x - b.x, y: a.y - b.y) }
    func rotated(by angle: CGFloat) -> NSPoint {
        NSPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
    var length: CGFloat { hypot(x, y) }
}

/// Rounds an angle to the nearest multiple of `step`.
func SWJNSnapAngle(_ angle: CGFloat, step: CGFloat = .pi / 12) -> CGFloat {
    (angle / step).rounded() * step
}
