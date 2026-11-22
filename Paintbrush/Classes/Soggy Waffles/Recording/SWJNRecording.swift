//
//  SWJNRecording.swift
//  Paintbrush
//
//  The data behind drawing replays. A recording is a list of segments, each a
//  run of frames: a frame is the pixels of one rectangle of the canvas (main
//  image with the buffer composited over it) at a moment in time. Replaying
//  the frames of the kept segments in order repaints the picture stroke by
//  stroke. Segments line up with undo: undoing drops the newest segment from
//  the replay, redoing brings it back.
//
//  On disk a recording is an append only log of the events that built it, so
//  nothing is lost if the app quits or crashes mid stroke. Loading runs the
//  log through the same state machine the live recorder uses.
//

import Foundation
import CoreGraphics

// MARK: Frames and segments

nonisolated struct SWJNPixelRect: Sendable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var isEmpty: Bool { width <= 0 || height <= 0 }

    func union(_ other: SWJNPixelRect) -> SWJNPixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = min(x, other.x), minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width), maxY = max(y + height, other.y + other.height)
        return SWJNPixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func clamped(width canvasWidth: Int, height canvasHeight: Int) -> SWJNPixelRect {
        let minX = max(x, 0), minY = max(y, 0)
        let maxX = min(x + width, canvasWidth), maxY = min(y + height, canvasHeight)
        return SWJNPixelRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }
}

/// The pixels of one rectangle of the canvas at a moment in time. Pixels are
/// packed premultiplied RGBA in bitmap data order, compressed with LZFSE.
/// A frame whose canvas size differs from the current one resizes the canvas
/// (cleared to transparent) before its pixels are applied.
nonisolated struct SWJNRecordedFrame: Sendable {
    var time: Double
    var canvasWidth: Int
    var canvasHeight: Int
    var rect: SWJNPixelRect
    var pixels: Data

    /// Packs and compresses `bytes` (rect.width * rect.height * 4 of them).
    init(time: Double, canvasWidth: Int, canvasHeight: Int, rect: SWJNPixelRect, rawPixels bytes: UnsafeRawBufferPointer) {
        self.time = time
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.rect = rect
        self.pixels = SWJNCompression.compress(bytes)
    }

    init(time: Double, canvasWidth: Int, canvasHeight: Int, rect: SWJNPixelRect, pixels: Data) {
        self.time = time
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.rect = rect
        self.pixels = pixels
    }

    var rawByteCount: Int { rect.width * rect.height * 4 }
}

nonisolated final class SWJNRecordedSegment {
    var registered: Bool
    var frames: [SWJNRecordedFrame] = []
    /// For each frame, the pixels it replaced, so undo can roll the recorder's
    /// picture back. Only frames recorded in this session have one.
    var reverts: [SWJNRecordedFrame?] = []

    // Live recorder bookkeeping, never stored
    var isLogged = false
    var undoGroup: AnyObject?

    init(registered: Bool) {
        self.registered = registered
    }
}

nonisolated enum SWJNRecordingEvent {
    /// The recorder started (app launch or document open). Redo is gone.
    case session(time: Double)
    /// The picture the recording starts from.
    case base(SWJNRecordedFrame)
    /// A new gesture or undoable action. Registered segments are undo steps.
    case begin(registered: Bool)
    /// The open segment became an undo step.
    case register
    /// Pixels changed. They go to the open segment, or the newest kept one.
    case frame(SWJNRecordedFrame, revert: SWJNRecordedFrame?)
    case undo
    case redo
    /// The whole picture after `keptCount` kept frames, so opening a long
    /// recording does not have to replay all of it.
    case snapshot(SWJNRecordedFrame, keptCount: Int)
}

// MARK: History

/// The segments of a recording, and what undo and redo do to them. The live
/// recorder and the log loader both drive this, so they always agree.
nonisolated final class SWJNRecordingHistory {
    /// Segment 0 holds the base picture and is never undone.
    private(set) var segments: [SWJNRecordedSegment] = []
    private(set) var redoStack: [[SWJNRecordedSegment]] = []
    private(set) var open: SWJNRecordedSegment?
    /// True once undo or redo has thrown something away, so the log is worth compacting.
    private(set) var hasDiscardedContent = false
    /// The latest snapshot, while nothing has changed since it was taken.
    private(set) var snapshot: (frame: SWJNRecordedFrame, keptCount: Int)?

    var keptFrameCount: Int { segments.reduce(0) { $0 + $1.frames.count } }

    var hasBase: Bool { !segments.isEmpty }

    /// Where the next frame goes.
    var frameTarget: SWJNRecordedSegment? { open ?? segments.last }

    /// Applies `event`. For undo, returns the segments it dropped; for redo, the
    /// ones it brought back.
    @discardableResult
    func apply(_ event: SWJNRecordingEvent) -> [SWJNRecordedSegment] {
        switch event {
        case .session:
            if !redoStack.isEmpty { hasDiscardedContent = true }
            redoStack = []
            open = nil
        case .base(let frame):
            snapshot = nil
            let segment = SWJNRecordedSegment(registered: true)
            segment.frames = [frame]
            segment.reverts = [nil]
            segments = [segment]
            redoStack = []
            open = nil
        case .begin(let registered):
            // A gesture that changed nothing leaves no trace
            if let open, !open.registered, open.frames.isEmpty, segments.last === open {
                segments.removeLast()
            }
            let segment = SWJNRecordedSegment(registered: registered)
            segments.append(segment)
            open = segment
            if registered { clearRedo() }
        case .register:
            if let open {
                open.registered = true
            } else {
                let segment = SWJNRecordedSegment(registered: true)
                segments.append(segment)
                open = segment
            }
            clearRedo()
        case .frame(let frame, let revert):
            guard let target = frameTarget else { return [] }
            snapshot = nil
            target.frames.append(frame)
            target.reverts.append(revert)
        case .undo:
            open = nil
            snapshot = nil
            guard let index = segments.lastIndex(where: { $0.registered }), index > 0 else { return [] }
            let dropped = Array(segments[index...])
            segments.removeSubrange(index...)
            redoStack.append(dropped)
            return dropped
        case .redo:
            open = nil
            snapshot = nil
            guard let restored = redoStack.popLast() else { return [] }
            segments.append(contentsOf: restored)
            return restored
        case .snapshot(let frame, let keptCount):
            snapshot = (frame, keptCount)
        }
        return []
    }

    private func clearRedo() {
        if !redoStack.isEmpty { hasDiscardedContent = true }
        redoStack = []
    }

    /// Every kept frame in replay order. The first is the base picture.
    var keptFrames: [SWJNRecordedFrame] {
        segments.flatMap(\.frames)
    }
}

// MARK: Log file

/// Binary log: "PBRC", a UInt16 version, then records of a UInt8 type, a
/// UInt32 payload length and the payload. Numbers are little endian. A
/// truncated last record (crash mid write) is ignored on load.
nonisolated enum SWJNRecordingLog {
    static let magic = Data("PBRC".utf8)
    static let version: UInt16 = 1

    private enum RecordType: UInt8 {
        case session = 1, base, begin, register, frame, undo, redo, snapshot
    }

    static var header: Data {
        var data = magic
        data.appendLE(version)
        return data
    }

    static func encode(_ event: SWJNRecordingEvent) -> Data {
        var payload = Data()
        let type: RecordType
        switch event {
        case .session(let time):
            type = .session
            payload.appendLE(time.bitPattern)
        case .base(let frame):
            type = .base
            encodeFrame(frame, into: &payload)
        case .begin(let registered):
            type = .begin
            payload.append(registered ? 1 : 0)
        case .register:
            type = .register
        case .frame(let frame, _):
            type = .frame
            encodeFrame(frame, into: &payload)
        case .undo:
            type = .undo
        case .redo:
            type = .redo
        case .snapshot(let frame, let keptCount):
            type = .snapshot
            payload.appendLE(UInt32(keptCount))
            encodeFrame(frame, into: &payload)
        }
        var record = Data([type.rawValue])
        record.appendLE(UInt32(payload.count))
        record.append(payload)
        return record
    }

    /// Reads a log into a history. Nil when the file is not a recording.
    static func load(_ data: Data) -> SWJNRecordingHistory? {
        guard data.count >= header.count, data.prefix(magic.count) == magic else { return nil }
        var reader = SWJNByteReader(data: data, offset: magic.count)
        guard let fileVersion: UInt16 = reader.read(), fileVersion == version else { return nil }

        let history = SWJNRecordingHistory()
        while let rawType: UInt8 = reader.read(), let length: UInt32 = reader.read() {
            guard let payload = reader.readBytes(Int(length)) else { break } // truncated tail
            guard let type = RecordType(rawValue: rawType) else { continue }
            var body = SWJNByteReader(data: payload, offset: 0)
            switch type {
            case .session:
                guard let bits: UInt64 = body.read() else { return history }
                history.apply(.session(time: Double(bitPattern: bits)))
            case .base:
                guard let frame = decodeFrame(&body) else { return history }
                history.apply(.base(frame))
            case .begin:
                guard history.hasBase, let flag: UInt8 = body.read() else { continue }
                history.apply(.begin(registered: flag != 0))
            case .register:
                guard history.hasBase else { continue }
                history.apply(.register)
            case .frame:
                guard history.hasBase, let frame = decodeFrame(&body) else { continue }
                history.apply(.frame(frame, revert: nil))
            case .undo:
                history.apply(.undo)
            case .redo:
                history.apply(.redo)
            case .snapshot:
                guard history.hasBase, let count: UInt32 = body.read(), let frame = decodeFrame(&body) else { continue }
                history.apply(.snapshot(frame, keptCount: Int(count)))
            }
        }
        return history.hasBase ? history : nil
    }

    /// A fresh log holding only what the replay shows.
    static func compacted(_ history: SWJNRecordingHistory, time: Double) -> Data {
        var data = header
        for (index, segment) in history.segments.enumerated() {
            if index == 0 {
                guard let base = segment.frames.first else { continue }
                data.append(encode(.base(base)))
                for frame in segment.frames.dropFirst() { data.append(encode(.frame(frame, revert: nil))) }
                continue
            }
            guard !segment.frames.isEmpty || segment.registered else { continue }
            data.append(encode(.begin(registered: segment.registered)))
            for frame in segment.frames { data.append(encode(.frame(frame, revert: nil))) }
        }
        if let snapshot = history.snapshot {
            data.append(encode(.snapshot(snapshot.frame, keptCount: snapshot.keptCount)))
        }
        data.append(encode(.session(time: time)))
        return data
    }

    private static func encodeFrame(_ frame: SWJNRecordedFrame, into data: inout Data) {
        data.appendLE(frame.time.bitPattern)
        for value in [frame.canvasWidth, frame.canvasHeight, frame.rect.x, frame.rect.y, frame.rect.width, frame.rect.height] {
            data.appendLE(UInt32(value))
        }
        data.append(frame.pixels)
    }

    private static func decodeFrame(_ reader: inout SWJNByteReader) -> SWJNRecordedFrame? {
        guard let bits: UInt64 = reader.read() else { return nil }
        var values: [Int] = []
        for _ in 0..<6 {
            guard let value: UInt32 = reader.read() else { return nil }
            values.append(Int(value))
        }
        let rect = SWJNPixelRect(x: values[2], y: values[3], width: values[4], height: values[5])
        guard values[0] > 0, values[1] > 0, !rect.isEmpty,
              rect.x + rect.width <= values[0], rect.y + rect.height <= values[1] else { return nil }
        return SWJNRecordedFrame(time: Double(bitPattern: bits), canvasWidth: values[0], canvasHeight: values[1],
                                 rect: rect, pixels: reader.remainder())
    }
}

nonisolated struct SWJNByteReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int) {
        self.data = data
        self.offset = offset
    }

    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        let start = data.startIndex + offset
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: data[start..<(start + size)]) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func remainder() -> Data {
        readBytes(data.count - offset) ?? Data()
    }
}

nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: Compression

/// Pixel blobs start with one byte saying how the rest is stored.
nonisolated enum SWJNCompression {
    private static let raw: UInt8 = 0
    private static let lzfse: UInt8 = 1
    private static let lz4: UInt8 = 2

    /// LZFSE is smaller (what goes on disk); `fast` uses LZ4 for in memory copies.
    static func compress(_ bytes: UnsafeRawBufferPointer, fast: Bool = false) -> Data {
        let data = NSData(bytes: bytes.baseAddress, length: bytes.count)
        if let compressed = try? data.compressed(using: fast ? .lz4 : .lzfse) as Data {
            return Data([fast ? lz4 : lzfse]) + compressed
        }
        return Data([raw]) + Data(bytes)
    }

    /// Decompresses into `destination`, which must hold exactly the raw size.
    static func decompress(_ data: Data, into destination: UnsafeMutableRawBufferPointer) -> Bool {
        guard let kind = data.first else { return false }
        let body = data.dropFirst()
        let pixels: Data
        switch kind {
        case raw:
            pixels = body
        case lzfse, lz4:
            let algorithm: NSData.CompressionAlgorithm = kind == lz4 ? .lz4 : .lzfse
            guard let decompressed = try? (Data(body) as NSData).decompressed(using: algorithm) as Data else { return false }
            pixels = decompressed
        default:
            return false
        }
        guard pixels.count == destination.count else { return false }
        pixels.withUnsafeBytes { destination.copyMemory(from: $0) }
        return true
    }
}

// MARK: Canvas

/// A packed RGBA picture that frames are applied to.
nonisolated final class SWJNReplayCanvas: @unchecked Sendable {
    private(set) var width = 0
    private(set) var height = 0
    var pixels: [UInt8] = []

    var rowBytes: Int { width * 4 }

    func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Paints `frame` onto the canvas. Returns false if its pixels are damaged.
    @discardableResult
    func apply(_ frame: SWJNRecordedFrame) -> Bool {
        if frame.canvasWidth != width || frame.canvasHeight != height {
            resize(width: frame.canvasWidth, height: frame.canvasHeight)
        }
        let rect = frame.rect
        if rect.x == 0, rect.y == 0, rect.width == width, rect.height == height {
            return pixels.withUnsafeMutableBytes { SWJNCompression.decompress(frame.pixels, into: $0) }
        }
        var patch = [UInt8](repeating: 0, count: frame.rawByteCount)
        guard patch.withUnsafeMutableBytes({ SWJNCompression.decompress(frame.pixels, into: $0) }) else { return false }
        let rowBytes = self.rowBytes
        patch.withUnsafeBytes { src in
            pixels.withUnsafeMutableBytes { dst in
                SWJNCopyPixels(src.baseAddress!.assumingMemoryBound(to: UInt8.self), rect.width * 4, 0, 0,
                               dst.baseAddress!.assumingMemoryBound(to: UInt8.self), rowBytes, Int32(rect.x), Int32(rect.y),
                               Int32(rect.width), Int32(rect.height))
            }
        }
        return true
    }

    func copy() -> SWJNReplayCanvas {
        let canvas = SWJNReplayCanvas()
        canvas.width = width
        canvas.height = height
        canvas.pixels = pixels
        return canvas
    }

    /// An image of the canvas in bitmap data order (draw it the way the paint view does).
    func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: Timeline

/// Plays a recording back: frames on a clock that keeps the speed of each
/// stroke but shortens long pauses, with seeking in both directions.
nonisolated final class SWJNReplayTimeline: @unchecked Sendable {
    /// Longest pause kept between two frames, in seconds.
    static let maxPause = 0.6

    let frames: [SWJNRecordedFrame]
    /// Replay time of each frame. The first (the starting picture) is at 0.
    let times: [Double]
    let duration: Double

    let canvas = SWJNReplayCanvas()
    /// How many frames are painted on the canvas.
    private(set) var appliedCount = 0
    /// Compressed copies of the canvas along the way, so seeking stays cheap
    /// on long recordings. Sorted by count.
    private var checkpoints: [(count: Int, width: Int, height: Int, pixels: Data)] = []
    private var bytesSinceCheckpoint = 0
    private var framesSinceCheckpoint = 0

    init(frames: [SWJNRecordedFrame]) {
        self.frames = frames
        var times: [Double] = []
        times.reserveCapacity(frames.count)
        var clock = 0.0
        for (index, frame) in frames.enumerated() {
            if index == 1 {
                clock = Self.leadIn
            } else if index > 1 {
                clock += min(max(frame.time - frames[index - 1].time, 0), Self.maxPause)
            }
            times.append(clock)
        }
        self.times = times
        self.duration = clock
    }

    /// Pause on the starting picture before the first stroke.
    static let leadIn = 0.3

    /// True when there is something to watch beyond the starting picture.
    var hasStrokes: Bool { frames.count > 1 }

    /// Paints the canvas as it was at `time`.
    func seek(to time: Double) {
        // Frames at or before `time`, always at least the starting picture
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid + 1 } else { high = mid }
        }
        apply(upTo: max(low, min(1, frames.count)))
    }

    func apply(upTo count: Int) {
        let target = min(count, frames.count)
        if let checkpoint = checkpoints.last(where: { $0.count <= target }),
           target < appliedCount || checkpoint.count > appliedCount {
            canvas.resize(width: checkpoint.width, height: checkpoint.height)
            canvas.pixels.withUnsafeMutableBytes { _ = SWJNCompression.decompress(checkpoint.pixels, into: $0) }
            appliedCount = checkpoint.count
            bytesSinceCheckpoint = 0
            framesSinceCheckpoint = 0
        } else if target < appliedCount {
            canvas.resize(width: 0, height: 0)
            appliedCount = 0
            bytesSinceCheckpoint = 0
            framesSinceCheckpoint = 0
        }
        while appliedCount < target {
            let frame = frames[appliedCount]
            canvas.apply(frame)
            appliedCount += 1
            bytesSinceCheckpoint += frame.rawByteCount
            framesSinceCheckpoint += 1
            // Saving a checkpoint costs about as much as applying a few thousand
            // small frames, so space them so that seeking never replays more than
            // roughly that many
            if bytesSinceCheckpoint > max(32 * 1024 * 1024, canvas.pixels.count * 4) || framesSinceCheckpoint >= 10_000 {
                saveCheckpoint()
            }
        }
    }

    private func saveCheckpoint() {
        bytesSinceCheckpoint = 0
        framesSinceCheckpoint = 0
        guard appliedCount > (checkpoints.last?.count ?? 0) else { return }
        let pixels = canvas.pixels.withUnsafeBytes { SWJNCompression.compress($0, fast: true) }
        checkpoints.append((appliedCount, canvas.width, canvas.height, pixels))
    }
}
