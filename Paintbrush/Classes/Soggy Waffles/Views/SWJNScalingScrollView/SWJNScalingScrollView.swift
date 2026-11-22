//
//  SWJNScalingScrollView.swift
//  Paintbrush
//
//  Created by Jarrod Norwell on 14/8/2026.
//

import Foundation

@objcMembers class SWJNScalingScrollView : NSScrollView {
    static var scaleStrings: [String] = [
        "10%",
        "25%",
        "50%",
        "75%",
        "100%",
        "125%",
        "150%",
        "175%",
        "200%",
        "400%"
    ]
    
    static var scaleFactors: [CGFloat] = [
        0.10,
        0.25,
        0.50,
        0.75,
        1.00,
        1.25,
        1.50,
        1.75,
        2.00,
        4.00
    ]
    
    var currentySelectedIndex: Int = 4
    
    @IBOutlet var scalePushButton: NSButton? = nil
    @IBOutlet var scaleDownItem: NSToolbarItem? = nil
    @IBOutlet var scaleUpItem: NSToolbarItem? = nil
    
    var scale: CGFloat = 1.00
    func setScale(to value: CGFloat, adjustingScalePushButton: Bool) {
        guard let documentView: NSView,
              let centeringClipView: SWJNCenteringClipView = documentView.superview as? SWJNCenteringClipView else {
            return
        }
        
        if scale.neq(to: value) {
            scale = value
            if adjustingScalePushButton, let scalePushButton: NSButton {
                scalePushButton.title = SWJNScalingScrollView.scaleStrings[currentySelectedIndex]
            }
            
            var bounds: NSRect = centeringClipView.bounds
            let oldBoundsSize: NSSize = bounds.size
            
            let frameSize: NSSize = centeringClipView.frame.size
            
            bounds.size.width = frameSize.width / scale
            bounds.size.height = frameSize.height / scale
            
            bounds.origin.x += (oldBoundsSize.width - bounds.width) / 2.0
            bounds.origin.y += (oldBoundsSize.height - bounds.height) / 2.0
            
            bounds = centeringClipView.constrainBoundsRect(bounds)
            centeringClipView.bounds = bounds
            
            guard let window: NSWindow else {
                return
            }
            
            var rect: NSRect = window.frame
            
            if value > 1.0 {
                let scrollerWidth: CGFloat = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
                
                var contentRect: NSRect = window.contentRect(forFrameRect: CGRect(origin: CGPoint(x: 0, y: 0),
                                                                                  size: CGSize(width: rect.size.width - scrollerWidth,
                                                                                               height: rect.size.height - scrollerWidth)))
                
                contentRect.size.width = round(contentRect.size.width / scale) * scale + scrollerWidth
                contentRect.size.height = round(contentRect.size.height / scale) * scale + scrollerWidth

                rect.size = window.frameRect(forContentRect: contentRect).size
            }
            
            let rescaleFactor: CGFloat = max(1.0, scale)
            
            window.resizeIncrements = CGSize(width: rescaleFactor, height: rescaleFactor)
            window.setFrame(rect, display: true, animate: true)
            
            bounds = centeringClipView.constrainBoundsRect(centeringClipView.bounds)
            centeringClipView.bounds = bounds
        }
    }
    
    func setScale(to value: CGFloat, at point: CGPoint, adjustingScalePushButton: Bool) {
        setScale(to: value, adjustingScalePushButton: adjustingScalePushButton)
        guard let documentView: NSView,
              let centeringClipView: SWJNCenteringClipView = documentView.superview as? SWJNCenteringClipView else {
            return
        }
        
        let size: CGSize = centeringClipView.bounds.size
        
        var point: CGPoint = point
        point.x -= size.width / 2
        point.y -= size.height / 2
        
        var bounds: NSRect = centeringClipView.bounds
        bounds.origin = point
        bounds = centeringClipView.constrainBoundsRect(bounds)
        
        centeringClipView.bounds = bounds
    }
    
    @IBAction func scaleDown(item: NSToolbarItem) {
        guard currentySelectedIndex >= 1 else {
            return
        }
        
        currentySelectedIndex -= 1
        setScale(to: SWJNScalingScrollView.scaleFactors[currentySelectedIndex], adjustingScalePushButton: true)
    }
    
    @IBAction func scaleUp(item: NSToolbarItem) {
        guard currentySelectedIndex <= 8 else {
            return
        }
        
        currentySelectedIndex += 1
        setScale(to: SWJNScalingScrollView.scaleFactors[currentySelectedIndex], adjustingScalePushButton: true)
    }
    
    // MARK: Zoom at the cursor

    static let minimumScale: CGFloat = 0.1
    static let maximumScale: CGFloat = 8

    /// Command + scroll zooms around the pointer; plain scrolling still scrolls.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // Trackpads send many small precise deltas, mouse wheels a few coarse lines
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        zoom(by: exp(event.scrollingDeltaY * sensitivity), at: event)
    }

    /// Pinch to zoom, also around the pointer.
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: event)
    }

    private func zoom(by factor: CGFloat, at event: NSEvent) {
        guard let clipView = contentView as? SWJNCenteringClipView, factor.isFinite, factor > 0 else { return }
        let newScale = min(max(scale * factor, Self.minimumScale), Self.maximumScale)
        guard newScale != scale else { return }

        // Keep the canvas point under the pointer fixed while the scale changes
        let anchor = clipView.convert(event.locationInWindow, from: nil)
        let old = clipView.bounds
        let fractionX = (anchor.x - old.minX) / old.width
        let fractionY = (anchor.y - old.minY) / old.height

        var bounds = NSRect.zero
        bounds.size = NSSize(width: clipView.frame.width / newScale, height: clipView.frame.height / newScale)
        bounds.origin = NSPoint(x: anchor.x - fractionX * bounds.width, y: anchor.y - fractionY * bounds.height)

        scale = newScale
        clipView.bounds = clipView.constrainBoundsRect(bounds)
        reflectScrolledClipView(clipView)

        // Let the zoom buttons step on from the closest preset
        let factors = SWJNScalingScrollView.scaleFactors
        currentySelectedIndex = factors.indices.min { abs(factors[$0] - newScale) < abs(factors[$1] - newScale) } ?? currentySelectedIndex
        scalePushButton?.title = "\(Int((newScale * 100).rounded()))%"
        window?.resizeIncrements = NSSize(width: 1, height: 1)
        documentView?.needsDisplay = true
    }

    // MARK: Panning

    /// Scrolls by a distance in screen points, so a key press moves the same amount at any zoom.
    func pan(byX dx: CGFloat, y dy: CGFloat) {
        guard let clipView = contentView as? SWJNCenteringClipView else { return }
        var bounds = clipView.bounds
        bounds.origin.x += dx / scale
        bounds.origin.y += dy / scale
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clipView)
    }

    func scaleToDefault() {
        currentySelectedIndex = 4
    }
    
    func scaleDown() -> Bool {
        guard currentySelectedIndex >= 1 else {
            return false
        }
        
        currentySelectedIndex -= 1
        return true
    }
    
    func scaleUp() -> Bool {
        guard currentySelectedIndex <= 8 else {
            return false
        }
        
        currentySelectedIndex += 1
        return true
    }
}
