//
//  SWJNImageImport.swift
//  Paintbrush
//
//  Reads an image off a pasteboard for Paste and drag and drop: copied image
//  data (screenshots, browsers) or an image file copied or dragged in Finder.
//

import Cocoa
import UniformTypeIdentifiers

@objcMembers class SWJNImageImport: NSObject {
    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    static func canRead(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions)
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        // Prefer the file, which keeps full resolution and transparency
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions)?.first as? URL,
           let image = NSImage(contentsOf: url) {
            return image
        }
        return pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }
}
