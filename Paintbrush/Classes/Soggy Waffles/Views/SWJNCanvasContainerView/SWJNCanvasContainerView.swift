//
//  SWJNCanvasContainerView.swift
//  Paintbrush
//
//  The scroll view's document view. It holds the paint view and is sized to
//  everything that should be scrollable: just the canvas, or the whole shirt
//  around a shirt canvas. Because the document really covers the shirt,
//  scrollers, elastic scrolling and zoom all agree on where you can go.
//

import Cocoa

@objcMembers class SWJNCanvasContainerView: NSView {
    let canvas: NSView

    init(canvas: NSView) {
        self.canvas = canvas
        super.init(frame: canvas.frame)
        addSubview(canvas)
        canvas.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(canvasFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: canvas)
        layoutCanvas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var isShirt: Bool { SWJNShirt.isShirtCanvas(canvas.frame.size) }

    /// The canvas in this view's coordinates, which are also the clip view's.
    var canvasRect: NSRect { canvas.frame }

    @objc private func canvasFrameChanged(_ notification: Notification) {
        layoutCanvas()
    }

    /// Sizes this view to its content and places the canvas inside it.
    private func layoutCanvas() {
        let size = canvas.frame.size
        var content = NSRect(origin: .zero, size: size)
        if SWJNShirt.isShirtCanvas(size) {
            content = SWJNShirt.bounds(around: content).integral
        }
        // Shift so the content starts at zero, with the canvas offset inside it
        let origin = NSPoint(x: -content.minX, y: -content.minY)
        if canvas.frame.origin != origin { canvas.setFrameOrigin(origin) }
        if frame.size != content.size { setFrameSize(content.size) }
        superview?.needsDisplay = true
    }
}
