import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnailer {
    public static let defaultMaxPixelSize = 480

    /// First frame of an image file, downsampled and with EXIF orientation applied.
    public static func image(at url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A representative frame of a video. `maxPixelSize` of nil keeps the full resolution.
    static func frame(ofVideoAt url: URL, at seconds: Double, maxPixelSize: Int? = defaultMaxPixelSize) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.conversionFailed("Cannot create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.conversionFailed("Cannot write \(url.lastPathComponent).")
        }
    }
}
