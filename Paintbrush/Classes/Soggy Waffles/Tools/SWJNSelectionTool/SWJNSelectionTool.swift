//
//  SWJNSelectionTool.swift
//  Paintbrush
//
//  Drag a box to select. The selected pixels lift off the canvas (leaving the
//  background color behind) and stay editable like placed text: drag to move,
//  corner squares to resize, the square above to rotate, arrow keys to nudge.
//  Pasted and dropped images arrive the same way. Click away, press Return or
//  switch tools to drop it; Delete throws it away.
//

import Cocoa

@objcMembers class SWJNSelectionTool: SWJNPlacementTool {
    /// The box being dragged out, before anything is lifted.
    private var marquee: NSRect?

    var hasSelection: Bool { placed is SWJNPlacedImage }

    /// Canvas area covered by the selection, for Crop. Empty without one.
    var cropRect: NSRect {
        guard let image = placed as? SWJNPlacedImage else { return .zero }
        return image.bounds.integral.intersection(paintView.bounds)
    }

    // MARK: Selecting

    override func creationEvent(_ mouseEvent: SWJNMouseEvent, at point: CGPoint,
                                main: NSBitmapImageRep, buffer: NSBitmapImageRep) {
        let rect = NSRect(x: min(savedPoint.x, point.x), y: min(savedPoint.y, point.y),
                          width: abs(point.x - savedPoint.x), height: abs(point.y - savedPoint.y))
            .intersection(paintView.bounds)

        switch mouseEvent {
        case .down:
            marquee = nil
        case .dragged:
            marquee = rect
            paintView.needsDisplay = true
        case .up:
            marquee = nil
            lift(rect)
        case .moved:
            break
        }
    }

    /// Selects the whole canvas (Command A).
    func selectAll() {
        commit()
        lift(paintView.bounds)
    }

    /// Cuts `rect` out of the main image and places it as an editable image.
    private func lift(_ rect: NSRect) {
        let rect = rect.integral
        guard let main = mainBitmapRep, rect.width >= 1, rect.height >= 1 else {
            paintView.needsDisplay = true
            return
        }

        // Undo goes back to before the pixels were lifted
        document.handleUndo(withImageData: nil, frame: .zero)

        // The main image is stored upside down (see SWDocument), so flip the
        // copy to keep every placed image upright
        let pixels = SWImageTools.cropImage(main, to: rect)!
        SWImageTools.flipImageVertical(pixels)

        SWLockFocus(main)
        NSGraphicsContext.current?.shouldAntialias = false
        backgroundColor.setFill()
        rect.fill(using: .copy)
        SWUnlockFocus(main)

        place(SWJNPlacedImage(image: pixels, topLeft: rect.origin), registerUndo: false)
    }

    // MARK: Paste

    /// Places `image` centered on `point` at the size it had on screen (a
    /// Retina screenshot lands at half its pixel count), shrunk if needed so
    /// it fits in the visible part of the canvas. Full resolution is kept, so
    /// enlarging it later stays sharp.
    func paste(_ image: NSImage, centeredAt point: NSPoint) {
        guard let bitmap = Self.bitmap(from: image) else { return }
        commit()

        let pixelWidth = CGFloat(bitmap.pixelsWide), pixelHeight = CGFloat(bitmap.pixelsHigh)
        let pointSize = image.size.width > 0 && image.size.height > 0
            ? image.size : NSSize(width: pixelWidth, height: pixelHeight)

        var room = paintView.visibleRect.intersection(paintView.bounds).size
        if room.width < 1 || room.height < 1 { room = paintView.bounds.size }
        let fit = min(1, room.width * 0.9 / pointSize.width, room.height * 0.9 / pointSize.height)
        let scale = pointSize.width * fit / pixelWidth

        // Keep the center on screen and the edges on whole pixels
        let size = NSSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let visible = paintView.visibleRect.intersection(paintView.bounds)
        let center = NSPoint(x: min(max(point.x, visible.minX + size.width / 2), visible.maxX - size.width / 2),
                             y: min(max(point.y, visible.minY + size.height / 2), visible.maxY - size.height / 2))
        let topLeft = NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())

        place(SWJNPlacedImage(image: bitmap, topLeft: topLeft, scale: scale))
    }

    /// Redraws `image` into an RGBA bitmap at its full pixel size.
    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        // Largest representation, so Retina screenshots keep every pixel
        var width = Int(image.size.width.rounded()), height = Int(image.size.height.rounded())
        for rep in image.representations where rep.pixelsWide * rep.pixelsHigh > width * height {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        }
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    // MARK: Copy

    /// The selection as it looks now (scaled and rotated), upright, for the
    /// pasteboard.
    func selectionImage() -> NSImage? {
        guard let selection = placed as? SWJNPlacedImage else { return nil }
        let bounds = selection.bounds.integral
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        var output: NSBitmapImageRep?
        SWImageTools.initImageRep(&output, with: bounds.size)
        guard let output else { return nil }
        SWImageTools.clearImage(output)

        SWLockFocus(output)
        let shift = NSAffineTransform()
        shift.translateX(by: -bounds.minX, yBy: -bounds.minY)
        shift.concat()
        selection.render()
        SWUnlockFocus(output)

        SWImageTools.flipImageVertical(output)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(output)
        return image
    }

    // MARK: Overlay

    override func drawOverlay(scale: CGFloat) {
        super.drawOverlay(scale: scale)
        guard let marquee, marquee.width > 0 || marquee.height > 0 else { return }

        // Light and dark dashes so the box shows on any color
        let path = NSBezierPath(rect: marquee)
        path.lineWidth = 1 / scale
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4 / scale, 4 / scale], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
    }

    override func finalise() {
        marquee = nil
        super.finalise()
    }

    nonisolated override var description: String {
        "Selection"
    }
}

/// Pixels lifted from the canvas or pasted in, kept upright at full
/// resolution. When shown smaller than that, a copy resized once with high
/// quality is drawn instead, so large pastes stay smooth and fast.
final class SWJNPlacedImage: SWJNTransformBox {
    private let image: NSBitmapImageRep
    private var shrunk: (scale: CGFloat, image: NSBitmapImageRep)?

    init(image: NSBitmapImageRep, topLeft: NSPoint, scale: CGFloat = 1) {
        self.image = image
        super.init(contentSize: NSSize(width: image.pixelsWide, height: image.pixelsHigh),
                   topLeft: topLeft, scale: scale)
    }

    override func drawContent() {
        guard let context = NSGraphicsContext.current else { return }
        let rect = NSRect(x: -contentSize.width / 2, y: -contentSize.height / 2,
                          width: contentSize.width, height: contentSize.height)
        context.shouldAntialias = !isUntransformed

        let scale = geometry.scale
        guard scale < 1 else {
            // Crisp pixels when kept or enlarged
            context.imageInterpolation = .none
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return
        }

        if isInteracting {
            // Quick and rough while a corner is being dragged
            context.imageInterpolation = .low
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return
        }

        if shrunk?.scale != scale { shrunk = Self.resized(image, scale: scale).map { (scale, $0) } }
        context.imageInterpolation = .high
        (shrunk?.image ?? image).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                      respectFlipped: false, hints: nil)
    }

    private static func resized(_ source: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep? {
        let width = max(1, Int((CGFloat(source.pixelsWide) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.pixelsHigh) * scale).rounded()))
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: output) else {
            return nil
        }
        output.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                    from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return output
    }
}

