//
//  SWJNToolboxView.swift
//  Paintbrush
//
//  Code-built toolbox: tools, shape fill, size, and a 5 slot color palette.
//

import Cocoa

@objcMembers class SWJNToolboxView: NSView {
    private struct ToolSpec {
        let title: String
        let image: NSImage?
        var shortcut: String? = nil
    }

    private static let tools: [ToolSpec] = [
        ToolSpec(title: "Brush", image: symbol("paintbrush.pointed"), shortcut: "Q"),
        ToolSpec(title: "Eraser", image: symbol("eraser"), shortcut: "W"),
        ToolSpec(title: "Zoom", image: symbol("magnifyingglass"), shortcut: "E"),
        ToolSpec(title: "Airbrush", image: sprayCanImage()),
        ToolSpec(title: "Line", image: symbol("line.diagonal")),
        ToolSpec(title: "Text", image: symbol("textformat")),
        ToolSpec(title: "Eyedropper", image: symbol("eyedropper")),
        ToolSpec(title: "Selection", image: symbol("rectangle.dashed")),
    ]

    private static let paletteDefaultsKey = "SWJNPaletteColors"
    static let paletteSize = 5

    private unowned let controller: SWToolboxController

    private var toolButtons: [NSButton] = []
    private var swatches: [SWJNColorSwatch] = []
    /// The color being drawn with, which may not be in the palette (eyedropper).
    private let currentSwatch = SWJNColorSwatch(color: .black, size: NSSize(width: 0, height: 22))
    private let sizeSlider = NSSlider(value: 3, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "3")

    private(set) var palette: [NSColor] = []
    private var editingSlot: Int?

    private(set) var brushButton: NSButton!

    init(controller: SWToolboxController) {
        self.controller = controller
        super.init(frame: .zero)
        palette = Self.loadPalette()
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let toolGrid = NSGridView(numberOfColumns: 4, rows: 0)
        toolGrid.rowSpacing = 6
        toolGrid.columnSpacing = 6
        for row in stride(from: 0, to: Self.tools.count, by: 4) {
            let buttons = Self.tools[row..<min(row + 4, Self.tools.count)].map(makeToolButton)
            toolButtons.append(contentsOf: buttons)
            toolGrid.addRow(with: buttons)
        }
        brushButton = toolButtons.first

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.toolTip = "Size (+ and - keys)"
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        sizeLabel.alignment = .right
        sizeLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let sizeRow = NSStackView(views: [sizeSlider, sizeLabel])
        sizeRow.spacing = 8

        currentSwatch.toolTip = "Current color"
        let paletteGrid = NSGridView(numberOfColumns: Self.paletteSize, rows: 0)
        paletteGrid.columnSpacing = 6
        paletteGrid.rowSpacing = 4
        swatches = (0..<Self.paletteSize).map { index in
            let swatch = SWJNColorSwatch(color: palette[index])
            swatch.toolTip = "Use color \(index + 1) (key \(index + 1))"
            swatch.onClick = { [weak self] in self?.selectPaletteIndex(index) }
            return swatch
        }
        let numberButtons: [NSButton] = (0..<Self.paletteSize).map { index in
            let button = NSButton(title: "\(index + 1)", target: self, action: #selector(editSlotTapped(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Change color \(index + 1)"
            return button
        }
        paletteGrid.addRow(with: swatches)
        paletteGrid.addRow(with: numberButtons)
        for column in 0..<Self.paletteSize { paletteGrid.column(at: column).xPlacement = .center }

        let stack = NSStackView(views: [
            header("Tools"), toolGrid,
            header("Size"), sizeRow,
            header("Colors"), currentSwatch, paletteGrid,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for gap in [toolGrid, sizeRow] { stack.setCustomSpacing(16, after: gap) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            sizeRow.widthAnchor.constraint(equalTo: toolGrid.widthAnchor),
            currentSwatch.widthAnchor.constraint(equalTo: paletteGrid.widthAnchor),
        ])
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeToolButton(_ spec: ToolSpec) -> NSButton {
        let toolTip = spec.shortcut.map { "\(spec.title) (\($0))" } ?? spec.title
        let button = iconButton(spec.image, toolTip: toolTip, action: #selector(toolTapped(_:)))
        // The controller and SWToolbox look tools up by this title.
        button.title = spec.title
        button.imagePosition = .imageOnly
        return button
    }

    private func iconButton(_ image: NSImage?, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        button.toolTip = toolTip
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    // MARK: Actions

    @objc private func toolTapped(_ sender: NSButton) {
        controller.changeCurrentTool(sender)
        sync()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        // No tick marks, so snap to whole sizes here
        sender.doubleValue = sender.doubleValue.rounded()
        controller.changeLineWidth(sender)
    }

    @objc private func editSlotTapped(_ sender: NSButton) {
        let slot = sender.tag
        editingSlot = slot
        selectPaletteIndex(slot)

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = palette[slot]
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.title = "Color \(slot + 1)"
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let slot = editingSlot else { return }
        palette[slot] = sender.color
        swatches[slot].color = sender.color
        Self.savePalette(palette)
        controller.foregroundColor = sender.color
    }

    /// Makes palette slot `index` the drawing color. Also used by the 1 to 5 keys.
    func selectPaletteIndex(_ index: Int) {
        guard palette.indices.contains(index) else { return }
        if editingSlot != index { editingSlot = nil }
        controller.foregroundColor = palette[index]
    }

    // MARK: Sync from controller

    /// Reflects the controller's current tool, fill style, size and color.
    func sync() {
        let tool = controller.currentTool ?? ""
        for button in toolButtons {
            button.contentTintColor = button.title == tool ? .controlAccentColor : .labelColor
        }

        let size = controller.lineWidthDisplay
        sizeSlider.integerValue = size
        sizeLabel.stringValue = "\(size)"

        let current = controller.foregroundColor
        if let current { currentSwatch.color = current }
        for swatch in swatches {
            swatch.isSelected = current.map { swatch.color.isSameColor(as: $0) } ?? false
        }
    }

    // MARK: Palette storage

    private static func loadPalette() -> [NSColor] {
        let fallback: [NSColor] = [
            .black,
            .white,
            NSColor(srgbRed: 0.90, green: 0.22, blue: 0.21, alpha: 1),
            NSColor(srgbRed: 0.12, green: 0.53, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 0.99, green: 0.85, blue: 0.21, alpha: 1),
        ]
        guard let data = UserDefaults.standard.data(forKey: paletteDefaultsKey),
              let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSColor.self, from: data),
              colors.count == paletteSize else {
            return fallback
        }
        return colors
    }

    private static func savePalette(_ colors: [NSColor]) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: colors, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: paletteDefaultsKey)
    }

    // MARK: Images

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// SF Symbols has no spray can, so draw one as a template image.
    private static func sprayCanImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            NSColor.black.set()

            let body = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 7.5, width: 8, height: 11), xRadius: 2, yRadius: 2)
            body.lineWidth = 1.4
            body.stroke()

            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 4.5, width: 6, height: 3), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(rect: NSRect(x: 6.5, y: 2, width: 2, height: 2.5)).fill()

            let mist: [(CGFloat, CGFloat)] = [(11.5, 2.5), (14, 1), (14, 4), (16.5, 2.5), (17, 0.5), (17, 5)]
            for (x, y) in mist {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A clickable color square with a selection ring.
final class SWJNColorSwatch: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    /// A zero width leaves the width to the caller's constraints.
    init(color: NSColor, size: NSSize = NSSize(width: 24, height: 24)) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        if size.width > 0 { widthAnchor.constraint(equalToConstant: size.width).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: 3, dy: 3)
        color.setFill()
        let fill = NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4)
        fill.fill()
        NSColor.separatorColor.setStroke()
        fill.lineWidth = 1
        fill.stroke()

        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSColor {
    func isSameColor(as other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        let tolerance: CGFloat = 0.002
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
            && abs(a.alphaComponent - b.alphaComponent) < tolerance
    }
}
