//
//  SWJNReplayWindowController.swift
//  Paintbrush
//
//  View > Replay Drawing: plays a document's recording back in its own
//  window, with play and pause (Space), a scrubber, speed, and Export Video.
//  The replay is a snapshot taken when the window opens.
//

import Cocoa
import UniformTypeIdentifiers

@objcMembers class SWJNReplayWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: SWJNReplayWindowController] = [:]
    private static let speeds: [Double] = [1, 2, 4, 8, 16, 32, 64]
    private static let speedKey = "SWJNReplaySpeed"

    private let key: ObjectIdentifier
    private let timeline: SWJNReplayTimeline
    private let documentName: String

    private let canvasView = SWJNReplayCanvasView()
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let speedPopUp = NSPopUpButton()
    private let exportButton = NSButton(title: "Export Video…", target: nil, action: nil)

    private var time = 0.0
    private var timer: Timer?
    private var lastTick = 0.0
    private var shownCount = -1
    private var exportSheet: SWJNReplayExportSheet?

    private var speed: Double { Self.speeds[max(speedPopUp.indexOfSelectedItem, 0)] }

    /// Shows the replay for `recorder`, reusing its window if one is open.
    static func show(recorder: SWJNRecorder, documentName: String, near parent: NSWindow?) {
        let key = ObjectIdentifier(recorder)
        if let existing = open[key] {
            existing.close()
        }
        let controller = SWJNReplayWindowController(key: key, timeline: recorder.makeTimeline(), documentName: documentName)
        open[key] = controller
        controller.present(near: parent)
    }

    /// Closes the replay of `recorder`, if open (its document is closing).
    static func close(recorder: SWJNRecorder) {
        open[ObjectIdentifier(recorder)]?.close()
    }

    private init(key: ObjectIdentifier, timeline: SWJNReplayTimeline, documentName: String) {
        self.key = key
        self.timeline = timeline
        self.documentName = documentName
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Replay of \(documentName)"
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func buildContent() {
        guard let window else { return }

        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.keyEquivalent = " "
        playButton.bezelStyle = .rounded
        playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        slider.maxValue = max(timeline.duration, 0.001)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        for speed in Self.speeds { speedPopUp.addItem(withTitle: "\(Int(speed))×") }
        let savedSpeed = UserDefaults.standard.double(forKey: Self.speedKey)
        speedPopUp.selectItem(at: Self.speeds.firstIndex(of: savedSpeed) ?? 0)
        speedPopUp.target = self
        speedPopUp.action = #selector(speedChanged)
        speedPopUp.toolTip = "Playback speed"

        exportButton.target = self
        exportButton.action = #selector(exportVideo)
        exportButton.bezelStyle = .rounded

        let controls = NSStackView(views: [playButton, slider, timeLabel, speedPopUp, exportButton])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [playButton, timeLabel, speedPopUp, exportButton] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSView()
        for view in [canvasView, separator, controls] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: root.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: canvasView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.topAnchor.constraint(equalTo: separator.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root

        let hasStrokes = timeline.hasStrokes
        for control in [playButton, slider, speedPopUp, exportButton] as [NSControl] { control.isEnabled = hasStrokes }
        canvasView.message = hasStrokes ? nil : "Nothing to replay yet. Draw something, then open this again."
        show(time: hasStrokes ? 0 : timeline.duration)
    }

    private func present(near parent: NSWindow?) {
        guard let window else { return }
        // Big enough to see the canvas, small enough to fit the screen
        let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let canvas = NSSize(width: max(timeline.frames.last?.canvasWidth ?? 400, 1),
                            height: max(timeline.frames.last?.canvasHeight ?? 300, 1))
        let fit = min(screen.width * 0.7 / canvas.width, (screen.height * 0.7 - 60) / canvas.height)
        let scale = fit >= 1 ? min(floor(fit), 4) : fit
        let content = NSSize(width: max(canvas.width * scale, 520), height: max(canvas.height * scale + 60, 320))
        window.setContentSize(content)
        window.center()
        showWindow(nil)
        if timeline.hasStrokes { play() }
    }

    // MARK: Playback

    @objc private func togglePlay() {
        timer == nil ? play() : pause()
    }

    private func play() {
        guard timeline.hasStrokes else { return }
        if time >= timeline.duration { time = 0 }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        playButton.title = "Pause"
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        playButton.title = time >= timeline.duration ? "Replay" : "Play"
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        time = min(time + (now - lastTick) * speed, timeline.duration)
        lastTick = now
        show(time: time)
        if time >= timeline.duration { pause() }
    }

    @objc private func scrubbed() {
        time = slider.doubleValue
        lastTick = ProcessInfo.processInfo.systemUptime
        show(time: time)
        if timer == nil { playButton.title = time >= timeline.duration ? "Replay" : "Play" }
    }

    @objc private func speedChanged() {
        UserDefaults.standard.set(speed, forKey: Self.speedKey)
    }

    private func show(time: Double) {
        timeline.seek(to: time)
        if timeline.appliedCount != shownCount {
            shownCount = timeline.appliedCount
            canvasView.image = timeline.canvas.makeImage()
        }
        slider.doubleValue = time
        timeLabel.stringValue = "\(Self.format(time)) of \(Self.format(timeline.duration))"
    }

    /// "12.4s" under a minute, "3m 5s" above.
    static func format(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        return "\(whole / 60)m \(whole % 60)s"
    }

    // MARK: Export

    @objc private func exportVideo() {
        guard let window else { return }
        pause()
        let options = SWJNReplayExportOptions(timeline: timeline, playbackSpeed: speed)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\((documentName as NSString).deletingPathExtension) replay.mov"
        panel.title = "Export Video"
        panel.prompt = "Export"
        panel.accessoryView = options.view
        let frames = timeline.frames
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            options.remember()
            let sheet = SWJNReplayExportSheet(frames: frames, options: options.current, url: url)
            self.exportSheet = sheet
            sheet.run(on: window) { [weak self] in self?.exportSheet = nil }
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        exportSheet?.cancel()
        Self.open[key] = nil
    }
}

/// The replay picture, scaled to fit. Whole number zoom keeps pixels crisp.
final class SWJNReplayCanvasView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }

    // Drawn the same way as the paint view (bitmaps store the bottom row first)
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        if let image, let context = NSGraphicsContext.current?.cgContext {
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let inset = bounds.insetBy(dx: 16, dy: 16)
            var scale = min(inset.width / width, inset.height / height)
            if scale >= 1 { scale = floor(scale) }
            let size = NSSize(width: width * scale, height: height * scale)
            let rect = NSRect(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2),
                              width: size.width, height: size.height)
            context.interpolationQuality = scale >= 1 ? .none : .high
            context.draw(image, in: rect)
        }

        if let message {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let text = NSAttributedString(string: message, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}

/// Progress sheet for Export Video. The export runs off the main thread.
final class SWJNReplayExportSheet: NSObject {
    private let frames: [SWJNRecordedFrame]
    private let options: SWJNVideoOptions
    private let url: URL
    private let cancelFlag = SWJNCancelFlag()
    private var panel: NSPanel?
    private var indicator: NSProgressIndicator?

    init(frames: [SWJNRecordedFrame], options: SWJNVideoOptions, url: URL) {
        self.frames = frames
        self.options = options
        self.url = url
    }

    func cancel() { cancelFlag.cancel() }

    func run(on window: NSWindow, completion: @escaping @MainActor () -> Void) {
        let indicator = NSProgressIndicator()
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let label = NSTextField(labelWithString: "Exporting video…")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, indicator, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        self.panel = panel
        window.beginSheet(panel)

        self.indicator = indicator
        let frames = frames, options = options, url = url, cancelFlag = cancelFlag
        Task { @MainActor in
            let error: String? = await Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try SWJNReplayVideoExporter.export(frames: frames, options: options, to: url, progress: { value in
                        Task { @MainActor in self?.indicator?.doubleValue = value }
                    }, isCancelled: { cancelFlag.isCancelled })
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            window.endSheet(panel)
            completion()
            if let error, !cancelFlag.isCancelled {
                let alert = NSAlert()
                alert.messageText = "Export failed"
                alert.informativeText = error
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    @objc private func cancelPressed() {
        cancelFlag.cancel()
    }
}

nonisolated final class SWJNCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// The options under the Export Video save panel: frame, background and length.
final class SWJNReplayExportOptions: NSObject {
    private static let formatKey = "SWJNVideoFormat"
    private static let backgroundKey = "SWJNVideoBlackBackground"
    private static let lengthKey = "SWJNVideoLength"
    /// Longest video for each length choice, in seconds. Zero follows the playback speed.
    private static let lengths: [Double] = [0, 15, 30, 60, 90]

    private let timeline: SWJNReplayTimeline
    private let playbackSpeed: Double
    private let formatPopUp = NSPopUpButton()
    private let backgroundPopUp = NSPopUpButton()
    private let lengthPopUp = NSPopUpButton()
    private let summary = NSTextField(labelWithString: "")
    private(set) var view = NSView()

    init(timeline: SWJNReplayTimeline, playbackSpeed: Double) {
        self.timeline = timeline
        self.playbackSpeed = playbackSpeed
        super.init()
        build()
    }

    var current: SWJNVideoOptions {
        var options = SWJNVideoOptions()
        options.frameSize = SWJNVideoOptions.formats[max(formatPopUp.indexOfSelectedItem, 0)].size
        options.blackBackground = backgroundPopUp.indexOfSelectedItem == 1
        let limit = Self.lengths[max(lengthPopUp.indexOfSelectedItem, 0)]
        if limit > 0 {
            // Speed up just enough to fit; never slow down below real time
            options.speed = max(timeline.duration / max(limit - SWJNReplayVideoExporter.endHold, 1), 1)
        } else {
            options.speed = playbackSpeed
        }
        return options
    }

    func remember() {
        let defaults = UserDefaults.standard
        defaults.set(formatPopUp.indexOfSelectedItem, forKey: Self.formatKey)
        defaults.set(backgroundPopUp.indexOfSelectedItem == 1, forKey: Self.backgroundKey)
        defaults.set(lengthPopUp.indexOfSelectedItem, forKey: Self.lengthKey)
    }

    private func build() {
        let defaults = UserDefaults.standard
        for format in SWJNVideoOptions.formats { formatPopUp.addItem(withTitle: format.title) }
        formatPopUp.selectItem(at: min(defaults.integer(forKey: Self.formatKey), SWJNVideoOptions.formats.count - 1))

        backgroundPopUp.addItems(withTitles: ["White", "Black"])
        backgroundPopUp.selectItem(at: defaults.bool(forKey: Self.backgroundKey) ? 1 : 0)

        lengthPopUp.addItem(withTitle: "Playback speed (\(Int(playbackSpeed))×)")
        for limit in Self.lengths.dropFirst() { lengthPopUp.addItem(withTitle: "Up to \(Int(limit)) seconds") }
        lengthPopUp.selectItem(at: min(defaults.integer(forKey: Self.lengthKey), Self.lengths.count - 1))

        for popUp in [formatPopUp, backgroundPopUp, lengthPopUp] {
            popUp.target = self
            popUp.action = #selector(changed)
        }
        summary.textColor = .secondaryLabelColor
        summary.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopUp],
            [NSTextField(labelWithString: "Background:"), backgroundPopUp],
            [NSTextField(labelWithString: "Length:"), lengthPopUp],
            [NSGridCell.emptyContentView, summary],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])
        changed()
        view.setFrameSize(view.fittingSize)
    }

    /// "1080 × 1920, 28.5s at 12×, canvas shown 2×"
    @objc private func changed() {
        let options = current
        let canvasWidth = timeline.frames.map(\.canvasWidth).max() ?? 1
        let canvasHeight = timeline.frames.map(\.canvasHeight).max() ?? 1
        let layout = SWJNReplayVideoExporter.layout(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                                    frameSize: options.frameSize)
        let length = SWJNReplayVideoExporter.length(duration: timeline.duration, speed: options.speed)
        let speed = options.speed < 10 ? String(format: "%.1f", options.speed) : String(Int(options.speed.rounded()))
        let scale = layout.scale >= 1 ? "\(Int(layout.scale))×" : String(format: "%.2f×", layout.scale)
        summary.stringValue = "\(layout.width) × \(layout.height), \(SWJNReplayWindowController.format(length)) at \(speed)×, canvas shown \(scale)"
    }
}
