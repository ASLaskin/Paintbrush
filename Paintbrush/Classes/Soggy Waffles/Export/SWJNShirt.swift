//
//  SWJNShirt.swift
//  Paintbrush
//
//  T-shirt canvas: a 12 x 16 inch print area painted at 50 px per inch, shown
//  with a shirt drawn around it. A canvas is a shirt canvas purely by its
//  size, so reopening a saved shirt PNG brings the shirt back.
//

import Cocoa

@objcMembers class SWJNShirt: NSObject {
    static let printInches = NSSize(width: 12, height: 16)
    static let pixelsPerInch: CGFloat = 50
    static let canvasSize = NSSize(width: printInches.width * pixelsPerInch, height: printInches.height * pixelsPerInch)

    /// Export scale that yields 300 DPI at full print size (3600 x 4800 px).
    static let exportScale = 6
    static let printDPI: CGFloat = 300

    static func isShirtCanvas(_ size: NSSize) -> Bool {
        size.width == canvasSize.width && size.height == canvasSize.height
    }

    // Shirt outline in inches: x from the print's center line, y down from the
    // top of the shoulders. Roughly an adult large tee.
    private static let printTopInches: CGFloat = 5
    private static let halfOutline: [NSPoint] = [
        NSPoint(x: 3.5, y: 0),     // collar edge
        NSPoint(x: 10, y: 1.2),    // shoulder
        NSPoint(x: 16, y: 7.5),    // sleeve end, top
        NSPoint(x: 13.2, y: 10.2), // sleeve end, bottom
        NSPoint(x: 11, y: 8.5),    // armpit
        NSPoint(x: 11, y: 30),     // hem corner
    ]
    private static let neckDepthInches: CGFloat = 3

    /// Converts shirt inches to coordinates around `canvas` (flipped, y down).
    private static func point(_ inches: NSPoint, around canvas: NSRect) -> NSPoint {
        NSPoint(x: canvas.midX + inches.x * pixelsPerInch,
                y: canvas.minY + (inches.y - printTopInches) * pixelsPerInch)
    }

    static func outline(around canvas: NSRect) -> NSBezierPath {
        let right = halfOutline.map { point($0, around: canvas) }
        let left = halfOutline.reversed().map { point(NSPoint(x: -$0.x, y: $0.y), around: canvas) }

        let path = NSBezierPath()
        path.move(to: right[0])
        right.dropFirst().forEach { path.line(to: $0) }
        left.forEach { path.line(to: $0) }

        // Front neckline, curving down between the two collar edges
        let neckLeft = point(NSPoint(x: -halfOutline[0].x, y: 0), around: canvas)
        let neckBottom = point(NSPoint(x: 0, y: neckDepthInches), around: canvas)
        path.curve(to: right[0],
                   controlPoint1: NSPoint(x: neckLeft.x, y: neckBottom.y),
                   controlPoint2: NSPoint(x: right[0].x, y: neckBottom.y))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// Area the shirt and its caption occupy, for scrolling and window sizing.
    @objc(boundsAroundCanvas:)
    static func bounds(around canvas: NSRect) -> NSRect {
        let outlineBounds = outline(around: canvas).bounds
        return outlineBounds.insetBy(dx: -40, dy: -40).union(captionRect(around: canvas, scale: 1))
    }

    static var caption: String {
        let exportWidth = Int(canvasSize.width) * exportScale
        let exportHeight = Int(canvasSize.height) * exportScale
        return "Print area \(Int(printInches.width)) × \(Int(printInches.height)) in, exports \(exportWidth) × \(exportHeight) px"
    }

    private static func captionAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13 / scale, weight: .medium),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    private static func captionRect(around canvas: NSRect, scale: CGFloat) -> NSRect {
        let size = (caption as NSString).size(withAttributes: captionAttributes(scale: scale))
        let hem = point(NSPoint(x: 0, y: 30), around: canvas)
        return NSRect(x: hem.x - size.width / 2, y: hem.y + 18 / scale, width: size.width, height: size.height)
    }

    /// Draws the shirt, the print area outline and the caption. Call before
    /// the canvas itself is drawn, in a flipped context. `scale` is the zoom.
    static func draw(around canvas: NSRect, scale: CGFloat) {
        let shirt = outline(around: canvas)
        NSColor(calibratedWhite: 0.34, alpha: 1).setFill()
        shirt.fill()
        shirt.lineWidth = 1.5 / scale
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
        shirt.stroke()

        let printBox = NSBezierPath(rect: canvas.insetBy(dx: -1 / scale, dy: -1 / scale))
        printBox.lineWidth = 1 / scale
        NSColor.controlAccentColor.setStroke()
        printBox.stroke()

        (caption as NSString).draw(in: captionRect(around: canvas, scale: scale),
                                   withAttributes: captionAttributes(scale: scale))
    }
}
