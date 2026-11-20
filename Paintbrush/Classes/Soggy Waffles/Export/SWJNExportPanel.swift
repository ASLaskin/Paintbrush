//
//  SWJNExportPanel.swift
//  Paintbrush
//
//  File > Export: saves a PNG copy scaled up by a whole number with no
//  smoothing (pixels stay crisp), optionally turning pure white transparent
//  for shirt printing. The document itself is left untouched.
//

import Cocoa

@objcMembers class SWJNExportPanel: NSObject {
    private static let scales = [1, 2, 3, 4, 6, 8]
    private static let scaleKey = "SWJNExportScale"
    private static let transparentKey = "SWJNExportTransparentWhite"

    private let image: NSBitmapImageRep
    private let isShirt: Bool
    private let scalePopUp = NSPopUpButton()
    private let transparentCheckbox = NSButton(checkboxWithTitle: "Make white transparent", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")

    /// `image` must be upright (top row first), like a saved file.
    init(image: NSBitmapImageRep, isShirt: Bool) {
        self.image = image
        self.isShirt = isShirt
        super.init()
    }

    /// Shows the save panel as a sheet on `window` and writes the PNG.
    func run(on window: NSWindow, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.title = "Export PNG"
        panel.prompt = "Export"
        panel.accessoryView = makeAccessoryView()

        // Keep self alive for the life of the sheet
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let scale = Self.scales[scalePopUp.indexOfSelectedItem]
            let transparent = transparentCheckbox.state == .on
            if !isShirt {
                UserDefaults.standard.set(scale, forKey: Self.scaleKey)
                UserDefaults.standard.set(transparent, forKey: Self.transparentKey)
            }
            do {
                try Self.pngData(from: image, scale: scale, transparentWhite: transparent).write(to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: Accessory view

    private func makeAccessoryView() -> NSView {
        for scale in Self.scales { scalePopUp.addItem(withTitle: "\(scale)×") }
        scalePopUp.target = self
        scalePopUp.action = #selector(optionsChanged)
        transparentCheckbox.target = self
        transparentCheckbox.action = #selector(optionsChanged)

        // Shirts default to print settings; everything else remembers the last choice
        let defaults = UserDefaults.standard
        let scale = isShirt ? SWJNShirt.exportScale : max(defaults.integer(forKey: Self.scaleKey), 1)
        scalePopUp.selectItem(at: Self.scales.firstIndex(of: scale) ?? 0)
        transparentCheckbox.state = (isShirt || defaults.bool(forKey: Self.transparentKey)) ? .on : .off

        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        updateSizeLabel()

        let scaleRow = NSStackView(views: [NSTextField(labelWithString: "Scale:"), scalePopUp, sizeLabel])
        scaleRow.spacing = 8
        let stack = NSStackView(views: [scaleRow, transparentCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.frame.size = stack.fittingSize
        return stack
    }

    @objc private func optionsChanged() {
        updateSizeLabel()
    }

    private func updateSizeLabel() {
        let scale = Self.scales[max(scalePopUp.indexOfSelectedItem, 0)]
        let width = image.pixelsWide * scale
        let height = image.pixelsHigh * scale
        let inches = { (pixels: Int) in String(format: "%g", (CGFloat(pixels) / SWJNShirt.printDPI * 10).rounded() / 10) }
        sizeLabel.stringValue = "\(width) × \(height) px, \(inches(width)) × \(inches(height)) in at 300 DPI"
    }

    // MARK: Rendering

    static func pngData(from source: NSBitmapImageRep, scale: Int, transparentWhite: Bool) throws -> Data {
        let width = source.pixelsWide * scale
        let height = source.pixelsHigh * scale
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: output) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        context.shouldAntialias = false
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                    from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        if transparentWhite, let pixels = output.bitmapData {
            // Only exact white goes, so light colors in the design survive.
            // Alpha is premultiplied, so a cleared pixel is all zeros.
            for row in 0..<height {
                let rowStart = pixels + row * output.bytesPerRow
                for column in 0..<width {
                    let pixel = rowStart + column * 4
                    if pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 255 && pixel[3] == 255 {
                        pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 0
                    }
                }
            }
        }

        // Record 300 DPI so print shops read the intended physical size
        output.size = NSSize(width: CGFloat(width) * 72 / SWJNShirt.printDPI,
                             height: CGFloat(height) * 72 / SWJNShirt.printDPI)

        guard let data = output.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
