//
//  SWJNCenteringClipView.swift
//  Paintbrush
//
//  Created by Jarrod Norwell on 15/8/2026.
//

import Foundation

@objcMembers class SWJNCenteringClipView : NSClipView {
    private var container: SWJNCanvasContainerView? { documentView as? SWJNCanvasContainerView }

    /// The canvas in this view's coordinates.
    private var canvasRect: NSRect? {
        guard let documentView else { return nil }
        guard let container else { return documentView.frame }
        return container.convert(container.canvasRect, to: self)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds: CGRect = super.constrainBoundsRect(proposedBounds)
        
        guard let documentRect = documentView?.frame else {
            return NSRect()
        }
        
        
        let maxX: CGFloat = documentRect.width - constrainedBounds.width
        let maxY: CGFloat = documentRect.height - constrainedBounds.height
        
        constrainedBounds.origin.x = if documentRect.width < constrainedBounds.width {
            round(documentRect.minX + maxX / 2.0)
        } else {
            round(max(documentRect.minX, min(constrainedBounds.origin.x, documentRect.minX + maxX)))
        }
        
        constrainedBounds.origin.y = if documentRect.height < constrainedBounds.height {
            round(documentRect.minY + maxY / 2.0)
        } else {
            round(max(documentRect.minY, min(constrainedBounds.origin.y, documentRect.minY + maxY)))
        }
        
        return constrainedBounds
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        
        guard let rect = canvasRect else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        
        if container?.isShirt == true {
            SWJNShirt.draw(around: rect, scale: frame.width / max(bounds.width, 1))
        }
        
        if shadow.isNil {
            shadow = NSShadow()
            guard let shadow: NSShadow else {
                return
            }
            
            shadow.shadowBlurRadius = 8.0
            shadow.shadowColor = NSColor.secondarySystemFill
            shadow.shadowOffset = .zero
        }
        
        if let shadow: NSShadow {
            shadow.set()
        }
        
        rect.fill()
        
        NSGraphicsContext.restoreGraphicsState()
    }
    
    override func viewBoundsChanged(_ notification: Notification) {
        super.viewBoundsChanged(notification)
        center()
    }
    
    override func viewFrameChanged(_ notification: Notification) {
        super.viewFrameChanged(notification)
        center()
    }
    
    
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        center()
    }
    
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        center()
    }
    
    override var frame: NSRect {
        didSet {
            center()
        }
    }
    
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        center()
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        center()
    }
    
    override var frameRotation: CGFloat {
        didSet {
            center()
        }
    }
    
    func center() {
        guard let documentRect = documentView?.frame else {
            return
        }
        
        var clipRect: CGRect = bounds
        
        if documentRect.width < clipRect.width {
            clipRect.origin.x = round(documentRect.minX + (documentRect.width - clipRect.width) / 2.0)
        }
        
        if documentRect.height < clipRect.height {
            clipRect.origin.y = round(documentRect.minY + (documentRect.height - clipRect.height) / 2.0)
        }
        
        scroll(to: clipRect.origin)
    }
}
