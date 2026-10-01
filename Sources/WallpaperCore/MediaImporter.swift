import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Copies or converts a user's file into the library folders and describes the result.
public enum MediaImporter {
    /// Content types offered in the open panel.
    public static let acceptedContentTypes: [UTType] = [.movie, .image]

    public static func canImport(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .image)
    }

    struct Destination {
        let mediaDirectory: URL
        let thumbnailDirectory: URL
    }

    static func importMedia(
        from url: URL,
        id: UUID,
        into destination: Destination,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Wallpaper {
        let fileExtension = url.pathExtension.lowercased()
        guard let type = contentType(of: url) else {
            throw ImportError.unsupportedFormat(fileExtension)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let format = (fileExtension.isEmpty ? type.preferredFilenameExtension ?? "" : fileExtension).uppercased()

        if type.conforms(to: .movie) {
            return try await importVideo(from: url, id: id, name: name, format: format, into: destination)
        }
        if type.conforms(to: .image) {
            return try await importImage(from: url, id: id, name: name, format: format, into: destination, progress: progress)
        }
        throw ImportError.unsupportedFormat(fileExtension)
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    // MARK: - Video

    private static func importVideo(
        from url: URL,
        id: UUID,
        name: String,
        format: String,
        into destination: Destination
    ) async throws -> Wallpaper {
        let info = try await VideoInfo.load(from: url)
        let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(fileExtension)"
        let mediaURL = destination.mediaDirectory.appendingPathComponent(fileName)
        // On APFS this is a clone, so even large videos are copied instantly.
        try FileManager.default.copyItem(at: url, to: mediaURL)

        let thumbnail = try? await Thumbnailer.frame(ofVideoAt: mediaURL, at: min(info.duration * 0.1, 2))
        return Wallpaper(
            id: id,
            name: name,
            kind: .video,
            fileName: fileName,
            thumbnailFileName: writeThumbnail(thumbnail, for: id, in: destination),
            sourceFormat: format,
            wasConverted: false,
            pixelWidth: info.width,
            pixelHeight: info.height,
            duration: info.duration,
            hasAudio: info.hasAudio,
            fileSize: fileSize(of: mediaURL)
        )
    }

    private struct VideoInfo {
        let width: Int
        let height: Int
        let duration: Double
        let hasAudio: Bool

        static func load(from url: URL) async throws -> VideoInfo {
            let asset = AVURLAsset(url: url)
            do {
                let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ImportError.noVideoTrack
                }
                let (naturalSize, transform, isDecodable) = try await track.load(
                    .naturalSize, .preferredTransform, .isDecodable
                )
                guard isPlayable, isDecodable, duration.seconds.isFinite, duration.seconds > 0 else {
                    throw ImportError.undecodableVideo
                }
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let size = naturalSize.applying(transform)
                return VideoInfo(
                    width: Int(abs(size.width).rounded()),
                    height: Int(abs(size.height).rounded()),
                    duration: duration.seconds,
                    hasAudio: !audioTracks.isEmpty
                )
            } catch let error as ImportError {
                throw error
            } catch {
                // AVFoundation recognised the file type but could not open it.
                throw ImportError.undecodableVideo
            }
        }
    }

    // MARK: - Images

    private static func importImage(
        from url: URL,
        id: UUID,
        name: String,
        format: String,
        into destination: Destination,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Wallpaper {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let thumbnail = Thumbnailer.image(at: url)
        else {
            throw ImportError.unreadable
        }
        let size = pixelSize(of: source)

        if AnimatedImageConverter.isAnimated(source) {
            let fileName = "\(id.uuidString).mov"
            let mediaURL = destination.mediaDirectory.appendingPathComponent(fileName)
            let output = try await AnimatedImageConverter.convert(source: url, to: mediaURL, progress: progress)
            return Wallpaper(
                id: id,
                name: name,
                kind: .video,
                fileName: fileName,
                thumbnailFileName: writeThumbnail(thumbnail, for: id, in: destination),
                sourceFormat: format,
                wasConverted: true,
                pixelWidth: size.width,
                pixelHeight: size.height,
                duration: output.duration,
                hasAudio: false,
                fileSize: fileSize(of: mediaURL)
            )
        }

        let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(fileExtension)"
        let mediaURL = destination.mediaDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: url, to: mediaURL)
        progress(1)
        return Wallpaper(
            id: id,
            name: name,
            kind: .image,
            fileName: fileName,
            thumbnailFileName: writeThumbnail(thumbnail, for: id, in: destination),
            sourceFormat: format,
            wasConverted: false,
            pixelWidth: size.width,
            pixelHeight: size.height,
            duration: nil,
            hasAudio: false,
            fileSize: fileSize(of: mediaURL)
        )
    }

    /// Pixel size of the first frame as displayed, i.e. with EXIF rotation applied.
    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    // MARK: - Helpers

    /// Returns the thumbnail's file name, or nil when there is nothing to write.
    private static func writeThumbnail(_ image: CGImage?, for id: UUID, in destination: Destination) -> String? {
        guard let image else { return nil }
        let fileName = "\(id.uuidString).jpg"
        do {
            try Thumbnailer.writeJPEG(image, to: destination.thumbnailDirectory.appendingPathComponent(fileName))
            return fileName
        } catch {
            return nil
        }
    }

    private static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
