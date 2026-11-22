//
//  SWJNShortcutsPanel.swift
//  Paintbrush
//
//  Floating panel listing every keyboard shortcut, toggled with H. Styled
//  like the toolbox. Canvas keys are listed here by hand (SWPaintView handles
//  them); menu shortcuts are read from the main menu so they never drift.
//

import Cocoa

@objcMembers class SWJNShortcutsPanelController: NSWindowController {
    static let shared = SWJNShortcutsPanelController()

    private typealias Row = (keys: String, action: String)
    private typealias Group = (title: String, rows: [Row])

    private static let canvasGroups: [Group] = [
        ("Tools", [
            ("Q", "Brush"),
            ("W", "Eraser"),
            ("E", "Zoom"),
        ]),
        ("Size and colors", [
            ("+  −", "Bigger or smaller size"),
            ("1 to 5", "Palette color"),
        ]),
        ("Canvas", [
            ("← → ↑ ↓", "Move placed item, or pan"),
            ("⇧ Arrows", "Move or pan further"),
            ("Return", "Place line, text or selection"),
            ("Delete", "Delete placed item"),
            ("Esc", "Stop current action"),
            ("⌘ Scroll", "Zoom at pointer"),
            ("Pinch", "Zoom at pointer"),
        ]),
        ("Panels", [
            ("M", "Show or hide toolbox"),
            ("H", "Show or hide shortcuts"),
        ]),
    ]

    /// Menus whose shortcuts are listed, in column order.
    private static let menuColumns: [[String]] = [["File", "Edit"], ["View", "Image", "Window"]]

    /// Menu actions that are not worth listing (text system leftovers and the like).
    private static let hiddenActions: Set<String> = [
        "performFindPanelAction:", "centerSelectionInVisibleArea:", "showGuessPanel:",
        "checkSpelling:", "pasteAsPlainText:", "runPageLayout:", "performMiniaturize:",
        "orderFrontCharacterPalette:",
    ]

    private var hasBeenShown = false

    init() {
        let panel = SWJNToolboxPanel(contentRect: .zero,
                                     styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "Keyboard Shortcuts"
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        guard let panel = window else { return }
        if panel.isVisible {
            close()
            return
        }

        // Rebuilt each time so the menu shortcuts are current
        let content = buildContent()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)

        if !hasBeenShown, let anchor = NSApp.mainWindow ?? NSApp.keyWindow {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: anchor.frame.midX - size.width / 2,
                                         y: anchor.frame.midY - size.height / 2))
            hasBeenShown = true
        }
        showWindow(nil)
    }

    // MARK: Content

    private func buildContent() -> NSView {
        var columns: [NSView] = [column(Self.canvasGroups)]
        for titles in Self.menuColumns {
            let groups = titles.compactMap(menuGroup)
            if !groups.isEmpty { columns.append(column(groups)) }
        }

        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 32
        row.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        return view
    }

    private func column(_ groups: [Group]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for group in groups {
            let grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.rowSpacing = 4
            grid.columnSpacing = 12
            for row in group.rows {
                grid.addRow(with: [keyLabel(row.keys), actionLabel(row.action)])
            }
            grid.column(at: 0).width = 72
            grid.setContentHuggingPriority(.required, for: .vertical)
            stack.addArrangedSubview(header(group.title))
            stack.addArrangedSubview(grid)
            stack.setCustomSpacing(16, after: grid)
        }
        // Shorter columns stay their own height instead of stretching to the tallest
        stack.setHuggingPriority(.required, for: .vertical)
        return stack
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func actionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    // MARK: Menu shortcuts

    private func menuGroup(_ title: String) -> Group? {
        guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu else { return nil }
        let rows: [Row] = menu.items.compactMap { item in
            // Alternates (Option variants) only appear while Option is held
            guard !item.isSeparatorItem, !item.isHidden, !item.isAlternate, !item.keyEquivalent.isEmpty else { return nil }
            if let action = item.action, Self.hiddenActions.contains(NSStringFromSelector(action)) { return nil }
            let name = item.title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            return (Self.format(item), name)
        }
        return rows.isEmpty ? nil : (title, rows)
    }

    /// "⇧⌘E" style text for a menu item's shortcut.
    private static func format(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        var flags = item.keyEquivalentModifierMask
        // An uppercase letter means Shift is part of the shortcut
        if key.count == 1, key != key.lowercased() { flags.insert(.shift) }

        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }
}
