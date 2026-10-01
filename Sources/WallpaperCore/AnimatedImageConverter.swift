import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Turns animated images (GIF, APNG, animated WebP, HEICS) into H.264 video, so every
/// wallpaper is played through the same hardware-decoded AVFoundation path. Decoding a large
/// GIF frame by frame on the CPU costs far more energy than playing the equivalent video.
public enum AnimatedImageConverter {
    public struct Output: Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let duration: Double
        public let frameCount: Int
    }

    /// Delay used for frames that declare (almost) no delay, matching what browsers do.
    static let fallbackFrameDelay = 0.1
    /// Small animations are enlarged by an integer factor up to roughly this width, with
    /// nearest-neighbour sampling, so pixel art stays crisp on large displays.
    static let upscaleTarget = 1920
    /// Hardware H.264 encoders reject very large frames; bigger animations are scaled down.
    static let maximumDimension = 3840
    static let maximumArea = 3840 * 2160

    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    // MARK: - Inspection

    /// Whether the image source is an animation rather than, say, a multi-image HEIC.
    public static func isAnimated(_ source: CGImageSource) -> Bool {
        CGImageSourceGetCount(source) > 1 && declaredDelay(of: source, at: 0) != nil
    }

    /// Display duration of every frame, in seconds.
    public static func frameDelays(of source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let delay = declaredDelay(of: source, at: index) ?? 0
            return delay < 0.011 ? fallbackFrameDelay : delay
        }
    }

    /// The delay stored in the frame's animation metadata, or nil if the frame has none.
    private static func declaredDelay(of source: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return nil
        }
        let containers: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for container in containers {
            guard let metadata = properties[container.dictionary] as? [CFString: Any] else { continue }
            if let delay = (metadata[container.unclamped] as? Double) ?? (metadata[container.clamped] as? Double) {
                return delay
            }
        }
        return nil
    }

    /// Size of the encoded video for an animation of the given size, and whether to scale it
    /// with nearest-neighbour sampling.
    static func outputSize(forWidth width: Int, height: Int) -> (width: Int, height: Int, nearestNeighbor: Bool) {
        let longest = max(width, height, 1)
        var scale = 1.0
        var nearestNeighbor = false
        if longest > maximumDimension {
            scale = Double(maximumDimension) / Double(longest)
        } else if longest * 2 <= upscaleTarget {
            scale = Double(upscaleTarget / longest)
            nearestNeighbor = true
        }
        let area = Double(width) * Double(height) * scale * scale
        if area > Double(maximumArea) {
            scale *= (Double(maximumArea) / area).squareRoot()
            nearestNeighbor = false
        }
        // H.264 needs even dimensions.
        func even(_ value: Double) -> Int { max(16, Int(value.rounded()) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale), nearestNeighbor)
    }

    static func bitRate(width: Int, height: Int, framesPerSecond: Double) -> Int {
        let fps = min(max(framesPerSecond, 1), 60)
        let estimate = Double(width * height) * fps * 0.15
        return Int(min(max(estimate, 2_000_000), 40_000_000))
    }

    // MARK: - Conversion

    /// Encodes the animation at `url` into a QuickTime movie at `destination`.
    /// `progress` is called on a background queue with values from 0 to 1.
    public static func convert(
        source url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try convertSynchronously(source: url, to: destination, progress: progress)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func convertSynchronously(source url: URL, to destination: URL, progress: (Double) -> Void) throws -> Output {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImportError.unreadable
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) else {
            throw ImportError.unreadable
        }

        let delays = frameDelays(of: source)
        let duration = delays.reduce(0, +)
        let size = outputSize(forWidth: firstFrame.width, height: firstFrame.height)
        let framesPerSecond = Double(frameCount) / max(duration, 0.001)

        try? FileManager.default.removeItem(at: destination)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        } catch {
            throw ImportError.conversionFailed(error.localizedDescription)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(width: size.width, height: size.height, framesPerSecond: framesPerSecond)
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else {
            throw ImportError.conversionFailed("The video encoder rejected the frame size.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Cannot start encoding.")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            var time = 0.0
            for index in 0..<frameCount {
                try autoreleasepool {
                    // A frame that fails to decode is skipped; the previous one stays on screen longer.
                    let image = index == 0 ? firstFrame : CGImageSourceCreateImageAtIndex(source, index, sourceOptions)
                    guard let image else { return }
                    let buffer = try makePixelBuffer(for: adaptor, width: size.width, height: size.height)
                    try draw(image, into: buffer, width: size.width, height: size.height, nearestNeighbor: size.nearestNeighbor)
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed {
                            throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Encoding failed.")
                        }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    let presentationTime = CMTime(seconds: time, preferredTimescale: 1000)
                    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                        throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Encoding failed.")
                    }
                }
                time += delays[index]
                progress(Double(index + 1) / Double(frameCount))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        input.markAsFinished()
        // Ending the session at the total duration keeps the last frame on screen for its full delay.
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 1000))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Encoding failed.")
        }
        return Output(pixelWidth: size.width, pixelHeight: size.height, duration: duration, frameCount: frameCount)
    }

    private static func videoSettings(width: Int, height: Int, framesPerSecond: Double) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height, framesPerSecond: framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(min(max(framesPerSecond.rounded(), 1), 60)),
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private static func makePixelBuffer(
        for adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            let attributes = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        }
        guard let buffer else {
            throw ImportError.conversionFailed("Cannot allocate a video frame.")
        }
        return buffer
    }

    private static func draw(
        _ image: CGImage,
        into buffer: CVPixelBuffer,
        width: Int,
        height: Int,
        nearestNeighbor: Bool
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            throw ImportError.conversionFailed("Cannot draw a video frame.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Transparent pixels become black: the desktop behind the wallpaper is never shown.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = nearestNeighbor ? .none : .high
        context.draw(image, in: bounds)
    }
}
