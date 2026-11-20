//
//  SWJNEraserTool.swift
//  Paintbrush
//
//  Created by Jarrod Norwell on 14/8/2026.
//

import Foundation

@objcMembers class SWJNEraserTool : SWJNTool {
    /// Eraser width in pixels for sizes 1 to 10. Grows much faster than the brush.
    private static let widths: [CGFloat] = [4, 8, 14, 20, 28, 38, 50, 64, 80, 100]

    override var effectiveWidth: CGFloat {
        // lineWidth is 2 * size - 2, so recover the 1 to 10 size
        let size = Int((lineWidth / 2).rounded()) + 1
        return Self.widths[min(max(size, 1), Self.widths.count) - 1]
    }

    override func bezierPath(from beginningPoint: CGPoint, to endingPoint: CGPoint) -> NSBezierPath? {
        if bezierPath.isNil {
            bezierPath = NSBezierPath()
        }
        
        guard let bezierPath: NSBezierPath else {
            return nil
        }
        
        bezierPath.lineWidth = effectiveWidth
        
        var from: NSPoint = beginningPoint
        from.x += 0.5
        from.y += 0.5
        
        var to: CGPoint = endingPoint
        to.x += 0.5
        to.y += 0.5
        
        bezierPath.move(to: from)
        bezierPath.line(to: to)
        
        return bezierPath
    }
    
    override func performDraw(from point: CGPoint,
                              on mainBitmap: NSBitmapImageRep, and bufferBitmap: NSBitmapImageRep,
                              for mouseEvent: SWJNMouseEvent) -> NSBezierPath? {
        _ = insertRedrawRect(from: point, to: savedPoint)
        
        switch mouseEvent {
        case .up:
            document.handleUndo(withImageData: nil, frame: .zero)
            
            SWImageTools.draw(toImage: mainBitmap, fromImage: bufferBitmap, withComposition: true)
            SWImageTools.clearImage(bufferBitmap)
            
            bezierPath = nil
            
            return nil
        default:
            SWLockFocus(bufferBitmap)
            
            SWImageTools.clearImage(bufferBitmap)
            
            if let context: NSGraphicsContext = NSGraphicsContext.current {
                context.shouldAntialias = false
                context.saveGraphicsState()
                context.compositingOperation = .copy
            }
            
            flags.contains(.option) ? foregroundColor.setStroke() : backgroundColor.setStroke()
            
            if let path = bezierPath(from: savedPoint, to: point) {
                path.stroke()
            }
            
            if let context: NSGraphicsContext = NSGraphicsContext.current {
                context.restoreGraphicsState()
            }
            
            savedPoint = point
            
            SWUnlockFocus(bufferBitmap)
            
            return nil
        }
    }
    
    nonisolated override var description: String {
        "Eraser"
    }
}
