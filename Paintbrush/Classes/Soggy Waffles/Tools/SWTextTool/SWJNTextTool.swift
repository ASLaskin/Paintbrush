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

    override init(document: SWDocument, paintView: SWPaintView?, toolbox: SWToolbox?, toolboxController: SWToolboxController) {
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

final class SWJNPlacedText: SWJNTransformBox {
    private let text: NSAttributedString

    init(text: NSAttributedString, topLeft: NSPoint) {
        self.text = text
        super.init(contentSize: text.size(), topLeft: topLeft)
    }

    override func drawContent() {
        NSGraphicsContext.current?.shouldAntialias = true
        text.draw(at: NSPoint(x: -contentSize.width / 2, y: -contentSize.height / 2))
    }
}
