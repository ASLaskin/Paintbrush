//
//  SWJNRecorder.swift
//  Paintbrush
//
//  Records a document's drawing for replay. It does not know about tools:
//  whenever the paint view is asked to redraw a rect, the recorder compares
//  what the canvas now shows (main image plus buffer) against its own copy of
//  the picture and keeps only the pixels that changed. That catches brush
//  strokes as they grow, shape previews, fills, pastes, the airbrush and
//  anything added later.
//
//  Segments follow undo: a gesture (mouse down to the next one) or a menu
//  action is a segment, it becomes an undo step when the document registers
//  undo, and undo or redo drop or restore whole segments. After either, any
//  difference left between the recorder's picture and the real canvas is
//  recorded as an instant fix, so a replay always ends on the real picture.
//

import Cocoa

@objcMembers class SWJNRecorder: NSObject {
    private let dataSource: SWImageDataSource
    private let undoManager: UndoManager?
    private var id: String
    private var history = SWJNRecordingHistory()
    private var log: FileHandle?

    /// The picture as the recording would replay it (packed RGBA, data order).
    private let shadow = SWJNReplayCanvas()

    private var pendingRect = SWJNPixelRect(x: 0, y: 0, width: 0, height: 0)
    private var pendingFull = false
    private var flushScheduled = false
    private var lastFlush = 0.0
    /// Captures happen at most this often (replay runs at 60 fps anyway).
    private static let captureInterval = 1.0 / 60.0

    // Reused pixel buffers, so drawing does not allocate on every capture
    private var regionBuffer: [UInt8] = []
    private var patchBuffer: [UInt8] = []
    private var revertBuffer: [UInt8] = []

    // Undo grouping: registrations made during one event belong to one undo step
    private var lastRegistrationEvent: NSEvent?
    private var undoGroupClosed = true
    private var observers: [NSObjectProtocol] = []

    private static var didRemoveOrphans = false

    /// Starts recording `dataSource`, continuing the recording linked to
    /// `fileURL` when there is one.
    init(dataSource: SWImageDataSource, fileURL: URL?, undoManager: UndoManager?) {
        self.dataSource = dataSource
        self.undoManager = undoManager
        self.id = fileURL.flatMap(SWJNRecordingStore.recordingID(for:)) ?? SWJNRecordingStore.newID()
        super.init()

        if !Self.didRemoveOrphans {
            Self.didRemoveOrphans = true
            SWJNRecordingStore.removeOrphans()
        }

        start(fileURL: fileURL)
        observeUndo()

        // Quitting does not always close documents first
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
                self?.writeSnapshot()
            }
        })
    }

    // MARK: Starting

    private func start(fileURL: URL?) {
        let now = Date().timeIntervalSinceReferenceDate
        let url = SWJNRecordingStore.logURL(for: id)

        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let loaded = SWJNRecordingLog.load(data) {
            history = loaded
            rebuildShadow()
            history.apply(.session(time: now))
            // Rewrite without undone strokes, or just add to the end
            if history.hasDiscardedContent {
                let compacted = SWJNRecordingLog.compacted(history, time: now)
                try? compacted.write(to: url, options: .atomic)
                openLog(at: url, writeHeader: false)
            } else {
                openLog(at: url, writeHeader: false)
                write(.session(time: now))
            }
            // The file may have been edited elsewhere, or saved lossy
            pendingFull = true
            flush()
        } else {
            // New recording, starting from whatever the canvas shows now
            if fileURL != nil, FileManager.default.fileExists(atPath: url.path) {
                // Unreadable log: start over under a new id rather than append to it
                id = SWJNRecordingStore.newID()
            }
            history = SWJNRecordingHistory()
            openLog(at: SWJNRecordingStore.logURL(for: id), writeHeader: true)
            let base = captureFullFrame(time: now)
            shadow.apply(base)
            history.apply(.base(base))
            write(.base(base))
            write(.session(time: now))
        }

        if let fileURL {
            SWJNRecordingStore.link(fileURL, to: id)
        }
    }

    private func openLog(at url: URL, writeHeader: Bool) {
        if writeHeader || !FileManager.default.fileExists(atPath: url.path) {
            try? SWJNRecordingLog.header.write(to: url, options: .atomic)
        }
        log = try? FileHandle(forWritingTo: url)
        _ = try? log?.seekToEnd()
    }

    private func write(_ event: SWJNRecordingEvent) {
        guard let log else { return }
        do {
            try log.write(contentsOf: SWJNRecordingLog.encode(event))
        } catch {
            // Disk full or the file went away: keep drawing, stop recording
            NSLog("Paintbrush: recording stopped: \(error)")
            try? log.close()
            self.log = nil
        }
    }

    /// Puts the recording's final picture in the shadow: from the snapshot
    /// when it is current, otherwise by replaying every kept frame.
    private func rebuildShadow() {
        shadow.resize(width: 0, height: 0)
        if let snapshot = history.snapshot, snapshot.keptCount == history.keptFrameCount, shadow.apply(snapshot.frame) {
            return
        }
        for frame in history.keptFrames { shadow.apply(frame) }
    }

    // MARK: Undo

    private func observeUndo() {
        guard let undoManager else { return }
        let center = NotificationCenter.default
        let handlers: [(Notification.Name, @MainActor (SWJNRecorder) -> Void)] = [
            (.NSUndoManagerDidCloseUndoGroup, { $0.undoGroupClosed = true }),
            (.NSUndoManagerWillUndoChange, { $0.flush() }),
            (.NSUndoManagerWillRedoChange, { $0.flush() }),
            (.NSUndoManagerDidUndoChange, { $0.didUndoOrRedo(.undo) }),
            (.NSUndoManagerDidRedoChange, { $0.didUndoOrRedo(.redo) }),
        ]
        for (name, handler) in handlers {
            observers.append(center.addObserver(forName: name, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { handler(self) }
                }
            })
        }
    }

    /// The document registered an undo step. Call after registering.
    func noteUndoRegistration() {
        let event = NSApp.currentEvent
        let sameStep = !undoGroupClosed && event != nil && event === lastRegistrationEvent
        undoGroupClosed = false
        lastRegistrationEvent = event

        flush()
        if let open = history.open, open.registered, sameStep {
            return // Another registration in the same undo step
        }
        if let open = history.open, !open.registered {
            if open.isLogged {
                write(.register)
            } else {
                write(.begin(registered: true))
                open.isLogged = true
            }
            history.apply(.register)
        } else {
            history.apply(.begin(registered: true))
            history.open?.isLogged = true
            write(.begin(registered: true))
        }
    }

    private func didUndoOrRedo(_ event: SWJNRecordingEvent) {
        // The pixels the undo just restored are not a stroke
        pendingRect = SWJNPixelRect(x: 0, y: 0, width: 0, height: 0)
        pendingFull = false

        let changed = history.apply(event)
        write(event)

        if case .undo = event {
            let reverts = changed.flatMap(\.reverts).reversed()
            if reverts.contains(where: { $0 == nil }) {
                rebuildShadow()
            } else {
                for revert in reverts { shadow.apply(revert!) }
            }
        } else {
            for frame in changed.flatMap(\.frames) { shadow.apply(frame) }
        }

        // Whatever still differs is recorded as an instant fix
        pendingFull = true
        flush()
    }

    // MARK: Gestures and changes

    /// A mouse press on the canvas starts a new segment.
    func beginGesture() {
        flush()
        history.apply(.begin(registered: false))
    }

    /// The paint view was asked to redraw `rect` (view coordinates, y down).
    func noteDirty(_ dirtyRect: NSRect) {
        let height = shadow.height
        // AppKit passes an endless rect for "everything"
        let rect = dirtyRect.intersection(NSRect(x: -4, y: -4, width: shadow.width + 8, height: height + 8))
        guard height > 0, !rect.isNull, !rect.isEmpty else { return }
        // View y runs down, bitmap rows run up; pad for antialiasing
        let minX = Int(floor(rect.minX)) - 2
        let maxX = Int(ceil(rect.maxX)) + 2
        let minRow = height - Int(ceil(rect.maxY)) - 2
        let maxRow = height - Int(floor(rect.minY)) + 2
        pendingRect = pendingRect.union(SWJNPixelRect(x: minX, y: minRow, width: maxX - minX, height: maxRow - minRow))
        scheduleFlush()
    }

    /// Something replaced the whole picture (reload after save, revert).
    func noteCanvasReplaced() {
        pendingFull = true
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = lastFlush + Self.captureInterval - ProcessInfo.processInfo.systemUptime
        if wait <= 0 {
            DispatchQueue.main.async { [weak self] in self?.flush() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
        }
    }

    /// Records whatever changed since the last look.
    func flush() {
        flushScheduled = false
        lastFlush = ProcessInfo.processInfo.systemUptime
        guard log != nil, pendingFull || !pendingRect.isEmpty else { return }
        defer {
            pendingFull = false
            pendingRect = SWJNPixelRect(x: 0, y: 0, width: 0, height: 0)
        }
        guard let main = dataSource.mainImage else { return }
        let time = Date().timeIntervalSinceReferenceDate
        let width = main.pixelsWide, height = main.pixelsHigh

        if width != shadow.width || height != shadow.height {
            // Canvas resized: the new picture replaces the old one
            let frame = captureFullFrame(time: time)
            let revert = shadowFrame(SWJNPixelRect(x: 0, y: 0, width: shadow.width, height: shadow.height), time: time)
            shadow.apply(frame)
            record(frame, revert: revert)
            return
        }

        let area = pendingFull ? SWJNPixelRect(x: 0, y: 0, width: width, height: height)
                               : pendingRect.clamped(width: width, height: height)
        guard !area.isEmpty else { return }

        Self.reserve(&regionBuffer, area.width * area.height * 4)
        composite(area, into: &regionBuffer)

        var dx: Int32 = 0, dy: Int32 = 0, dw: Int32 = 0, dh: Int32 = 0
        let changed = regionBuffer.withUnsafeBytes { regionBytes in
            shadow.pixels.withUnsafeBytes { shadowBytes in
                SWJNDiffBounds(regionBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(area.width), Int32(area.height),
                               shadowBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32(width),
                               Int32(area.x), Int32(area.y), &dx, &dy, &dw, &dh)
            }
        }
        guard changed != 0 else { return }

        let rect = SWJNPixelRect(x: area.x + Int(dx), y: area.y + Int(dy), width: Int(dw), height: Int(dh))
        let patchSize = rect.width * rect.height * 4
        Self.reserve(&patchBuffer, patchSize)
        regionBuffer.withUnsafeBytes { src in
            patchBuffer.withUnsafeMutableBytes { dst in
                SWJNCopyPixels(src.baseAddress!.assumingMemoryBound(to: UInt8.self), area.width * 4, dx, dy,
                               dst.baseAddress!.assumingMemoryBound(to: UInt8.self), rect.width * 4, 0, 0, dw, dh)
            }
        }
        let revert = shadowFrame(rect, time: time)
        let frame = patchBuffer.withUnsafeBytes {
            SWJNRecordedFrame(time: time, canvasWidth: width, canvasHeight: height, rect: rect,
                              rawPixels: UnsafeRawBufferPointer(rebasing: $0[..<patchSize]))
        }
        shadow.apply(frame)
        record(frame, revert: revert)
    }

    private func record(_ frame: SWJNRecordedFrame, revert: SWJNRecordedFrame?) {
        if let open = history.open, history.frameTarget === open, !open.isLogged {
            write(.begin(registered: open.registered))
            open.isLogged = true
        }
        history.apply(.frame(frame, revert: revert))
        write(.frame(frame, revert: nil))
    }

    // MARK: Pixels

    /// The shadow's pixels in `rect`, as a frame that puts them back.
    private func shadowFrame(_ rect: SWJNPixelRect, time: Double) -> SWJNRecordedFrame? {
        guard !rect.isEmpty else { return nil }
        let size = rect.width * rect.height * 4
        Self.reserve(&revertBuffer, size)
        let rowBytes = shadow.rowBytes
        shadow.pixels.withUnsafeBytes { src in
            revertBuffer.withUnsafeMutableBytes { dst in
                SWJNCopyPixels(src.baseAddress!.assumingMemoryBound(to: UInt8.self), rowBytes, Int32(rect.x), Int32(rect.y),
                               dst.baseAddress!.assumingMemoryBound(to: UInt8.self), rect.width * 4, 0, 0,
                               Int32(rect.width), Int32(rect.height))
            }
        }
        return revertBuffer.withUnsafeBytes {
            SWJNRecordedFrame(time: time, canvasWidth: shadow.width, canvasHeight: shadow.height, rect: rect,
                              rawPixels: UnsafeRawBufferPointer(rebasing: $0[..<size]))
        }
    }

    /// Grows a reusable buffer to at least `count` bytes. Contents are not cleared.
    private static func reserve(_ buffer: inout [UInt8], _ count: Int) {
        if buffer.count < count {
            buffer = [UInt8](repeating: 0, count: count)
        }
    }

    private func captureFullFrame(time: Double) -> SWJNRecordedFrame {
        let width = max(dataSource.mainImage?.pixelsWide ?? 1, 1)
        let height = max(dataSource.mainImage?.pixelsHigh ?? 1, 1)
        let rect = SWJNPixelRect(x: 0, y: 0, width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        composite(rect, into: &bytes)
        return bytes.withUnsafeBytes {
            SWJNRecordedFrame(time: time, canvasWidth: width, canvasHeight: height, rect: rect, rawPixels: $0)
        }
    }

    /// What the paint view shows in `rect`: the main image with the buffer over it.
    private func composite(_ rect: SWJNPixelRect, into destination: inout [UInt8]) {
        guard let main = dataSource.mainImage else { return }
        let height = main.pixelsHigh
        let buffer = dataSource.bufferImage
        let bufferWidth = buffer?.pixelsWide ?? 0
        let bufferHeight = buffer?.pixelsHigh ?? 0

        Self.withPixels(of: main) { mainBase, mainRowBytes in
            guard let mainBase else { return }
            Self.withPixels(of: buffer) { bufferBase, bufferRowBytes in
                destination.withUnsafeMutableBytes { dst in
                    SWJNCompositeRect(mainBase, mainRowBytes, bufferBase, bufferRowBytes,
                                      Int32(bufferWidth), Int32(bufferHeight), Int32(height - bufferHeight),
                                      Int32(rect.x), Int32(rect.y), Int32(rect.width), Int32(rect.height),
                                      dst.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }
    }

    /// Calls `body` with the bitmap's pixels as 8 bit RGBA, premultiplied, alpha
    /// last (the format Paintbrush creates). Other formats are converted first.
    private static func withPixels(of rep: NSBitmapImageRep?, _ body: (UnsafePointer<UInt8>?, Int) -> Void) {
        guard let rep else { return body(nil, 0) }
        let unsupported: NSBitmapImageRep.Format = [.alphaFirst, .alphaNonpremultiplied, .floatingPointSamples,
                                                    .sixteenBitBigEndian, .sixteenBitLittleEndian,
                                                    .thirtyTwoBitBigEndian, .thirtyTwoBitLittleEndian]
        if rep.bitsPerPixel == 32, rep.samplesPerPixel == 4, rep.bitsPerSample == 8, !rep.isPlanar,
           rep.bitmapFormat.isDisjoint(with: unsupported), let data = rep.bitmapData {
            return body(UnsafePointer(data), rep.bytesPerRow)
        }

        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 0, height > 0, let image = rep.cgImage else { return body(nil, 0) }
        var converted = [UInt8](repeating: 0, count: width * height * 4)
        converted.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        converted.withUnsafeBufferPointer { body($0.baseAddress, width * 4) }
    }

    // MARK: Saving and closing

    /// After a save, link the file to this recording. Save As to a new file
    /// copies the recording first so the old file keeps its own history.
    func didSave(to url: URL, previousURL: URL?) {
        flush()
        if let previousURL, previousURL.standardizedFileURL != url.standardizedFileURL,
           FileManager.default.fileExists(atPath: previousURL.path),
           let forked = SWJNRecordingStore.fork(id) {
            try? log?.close()
            id = forked
            openLog(at: SWJNRecordingStore.logURL(for: id), writeHeader: false)
        }
        SWJNRecordingStore.link(url, to: id)
    }

    /// Stops recording. Untitled documents closed without saving take their recording with them.
    func close(discard: Bool) {
        flush()
        if !discard { writeSnapshot() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        try? log?.close()
        log = nil
        if discard {
            SWJNRecordingStore.delete(id)
        }
    }

    /// Saves the current picture so the next open can skip replaying the
    /// whole history. Skipped when nothing changed since the last one.
    private func writeSnapshot() {
        guard log != nil, history.snapshot == nil, shadow.width > 0,
              let full = shadowFrame(SWJNPixelRect(x: 0, y: 0, width: shadow.width, height: shadow.height),
                                     time: Date().timeIntervalSinceReferenceDate) else { return }
        let event = SWJNRecordingEvent.snapshot(full, keptCount: history.keptFrameCount)
        history.apply(event)
        write(event)
    }

    // MARK: Replay

    /// A snapshot of the recording for playback.
    func makeTimeline() -> SWJNReplayTimeline {
        flush()
        return SWJNReplayTimeline(frames: history.keptFrames)
    }
}
