//
//  SWJNReplayVideoExporter.swift
//  Paintbrush
//
//  Writes a replay to a QuickTime movie (H.264, 30 fps) at the chosen speed.
//  Pixels are scaled up by a whole number when they fit, so they stay crisp,
//  and transparent areas are shown over white.
//

import AVFoundation
import CoreGraphics

/// How the exported video is framed and timed.
nonisolated struct SWJNVideoOptions: Sendable {
    /// Video frame size, or nil to follow the canvas shape.
    var frameSize: (width: Int, height: Int)?
    /// What shows around the canvas when its shape differs from the frame, and under transparent pixels.
    var blackBackground = false
    /// Replay speed (1 is real time, with long pauses shortened).
    var speed: Double = 1

    static let formats: [(title: String, size: (width: Int, height: Int)?)] = [
        ("Instagram Reel 9:16 (1080 × 1920)", (1080, 1920)),
        ("Instagram Portrait 3:4 (1080 × 1440)", (1080, 1440)),
        ("Instagram Portrait 4:5 (1080 × 1350)", (1080, 1350)),
        ("Instagram Square 1:1 (1080 × 1080)", (1080, 1080)),
        ("Landscape 16:9 (1920 × 1080)", (1920, 1080)),
        ("Same shape as canvas", nil),
    ]
}

nonisolated enum SWJNReplayVideoExporter {
    enum ExportError: LocalizedError {
        case cannotStart(Error?)
        case cancelled
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotStart(let error): return "The video could not be started. \(error?.localizedDescription ?? "")"
            case .cancelled: return "The export was cancelled."
            case .failed(let error): return "The video could not be written. \(error?.localizedDescription ?? "")"
            }
        }
    }

    static let framesPerSecond = 30
    /// How long the finished picture stays on screen at the end, in seconds.
    static let endHold = 1.5
    private static let longestSide = 1920.0

    /// Video size and canvas scale. The canvas is fitted inside the frame and
    /// centered; scales of 1 or more are whole numbers so pixels stay crisp.
    static func layout(canvasWidth: Int, canvasHeight: Int,
                       frameSize: (width: Int, height: Int)?) -> (width: Int, height: Int, scale: Double) {
        let cw = Double(max(canvasWidth, 1)), ch = Double(max(canvasHeight, 1))
        if let frameSize {
            var scale = min(Double(frameSize.width) / cw, Double(frameSize.height) / ch)
            if scale >= 1 { scale = floor(scale) }
            return (frameSize.width, frameSize.height, scale)
        }
        var scale = longestSide / max(cw, ch)
        if scale >= 1 { scale = floor(scale) }
        // H.264 wants even dimensions
        let width = max(Int((cw * scale).rounded()) / 2 * 2, 2)
        let height = max(Int((ch * scale).rounded()) / 2 * 2, 2)
        return (width, height, scale)
    }

    /// Length of the video in seconds, including the hold at the end.
    static func length(duration: Double, speed: Double) -> Double {
        duration / max(speed, 0.01) + endHold
    }

    /// Runs on a background thread. `progress` gets 0 to 1; return true from
    /// `isCancelled` to stop (the partial file is removed).
    static func export(frames: [SWJNRecordedFrame], options: SWJNVideoOptions, to url: URL,
                       progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        let timeline = SWJNReplayTimeline(frames: frames)
        guard let first = frames.first else { throw ExportError.cannotStart(nil) }
        // The largest canvas the recording reaches sets the video size
        let canvasWidth = frames.map(\.canvasWidth).max() ?? first.canvasWidth
        let canvasHeight = frames.map(\.canvasHeight).max() ?? first.canvasHeight
        let size = layout(canvasWidth: canvasWidth, canvasHeight: canvasHeight, frameSize: options.frameSize)
        let speed = options.speed

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ExportError.cannotStart(error)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(size.width * size.height * framesPerSecond / 3, 2_000_000),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        guard writer.canAdd(input) else { throw ExportError.cannotStart(nil) }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.cannotStart(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let playTime = timeline.duration / max(speed, 0.01)
        let total = Int(ceil(playTime * Double(framesPerSecond))) + Int(endHold * Double(framesPerSecond))
        var image: CGImage?
        var appliedCount = -1

        for index in 0...total {
            if isCancelled() {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw ExportError.cancelled
            }

            timeline.seek(to: Double(index) / Double(framesPerSecond) * speed)
            if timeline.appliedCount != appliedCount {
                appliedCount = timeline.appliedCount
                image = timeline.canvas.makeImage()
            }

            guard let pool = adaptor.pixelBufferPool else { throw ExportError.failed(writer.error) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw ExportError.failed(nil) }
            render(image, scale: size.scale, black: options.blackBackground, into: pixelBuffer, width: size.width, height: size.height)

            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw ExportError.failed(writer.error) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else { throw ExportError.failed(writer.error) }
            if index % 15 == 0 { progress(Double(index) / Double(max(total, 1))) }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw ExportError.failed(writer.error) }
    }

    private static func render(_ image: CGImage?, scale: Double, black: Bool, into pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        context.setFillColor(CGColor(gray: black ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image else { return }

        context.interpolationQuality = scale >= 1 ? .none : .high
        // Canvas bitmaps store the bottom row first, so flip to stand it upright
        let drawn = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        let origin = CGPoint(x: floor((Double(width) - drawn.width) / 2), y: floor((Double(height) - drawn.height) / 2))
        context.translateBy(x: origin.x, y: origin.y + drawn.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: drawn)
    }
}
