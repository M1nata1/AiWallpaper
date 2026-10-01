import CoreGraphics
import Foundation
import ImageIO

/// One decoded cursor: its animation frames, how long each is shown, and the hotspot.
public struct DecodedCursor {
    public var frames: [CGImage]
    /// Seconds per frame, same count as `frames`. Zero means a static cursor.
    public var frameDurations: [Double]
    /// Click point, in pixels of the frame image (top-left origin, as stored in the file).
    public var hotSpot: CGPoint
    public var pixelSize: CGSize

    public var isAnimated: Bool { frames.count > 1 }

    public init(frames: [CGImage], frameDurations: [Double], hotSpot: CGPoint, pixelSize: CGSize) {
        self.frames = frames
        self.frameDurations = frameDurations
        self.hotSpot = hotSpot
        self.pixelSize = pixelSize
    }
}

/// Decodes Windows cursors (`.ani`, `.cur`), Windows icons (`.ico`) and ordinary still images
/// into frames macOS can draw. macOS has no decoder for `.cur`/`.ani`, so this parses the
/// containers by hand and hands the pixel data to ImageIO through the `.ico` path.
public enum CursorImageDecoder {
    public static func decode(contentsOf url: URL) -> DecodedCursor? {
        (try? Data(contentsOf: url)).flatMap(decode(data:))
    }

    public static func decode(data: Data) -> DecodedCursor? {
        let bytes = [UInt8](data)
        if bytes.count >= 12, fourCC(bytes, 0) == "RIFF", fourCC(bytes, 8) == "ACON" {
            return decodeANI(bytes)
        }
        if bytes.count >= 22, read16(bytes, 0) == 0, (1...2).contains(read16(bytes, 2)), read16(bytes, 4) >= 1 {
            if let frame = decodeCUR(bytes) {
                return DecodedCursor(
                    frames: [frame.image], frameDurations: [0], hotSpot: frame.hotSpot,
                    pixelSize: CGSize(width: frame.image.width, height: frame.image.height)
                )
            }
        }
        // Any still image (PNG, TIFF, …) becomes a single-frame cursor with the hotspot at 0,0.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return DecodedCursor(
                frames: [image], frameDurations: [0], hotSpot: .zero,
                pixelSize: CGSize(width: image.width, height: image.height)
            )
        }
        return nil
    }

    // MARK: - .ani (RIFF "ACON")

    private static func decodeANI(_ bytes: [UInt8]) -> DecodedCursor? {
        var pos = 12
        var defaultJiffies = 10
        var rates: [Int] = []
        var sequence: [Int] = []
        var frameBlobs: [[UInt8]] = []

        while pos + 8 <= bytes.count {
            let id = fourCC(bytes, pos)
            let size = read32(bytes, pos + 4)
            let body = pos + 8
            guard size >= 0, body + size <= bytes.count else { break }
            switch id {
            case "anih":
                // ANIHEADER: nFrames at +4, iDispRate (default jiffies) at +28.
                if size >= 36 { defaultJiffies = read32(bytes, body + 28) }
            case "rate":
                rates = stride(from: body, to: body + size, by: 4).map { read32(bytes, $0) }
            case "seq ":
                sequence = stride(from: body, to: body + size, by: 4).map { read32(bytes, $0) }
            case "LIST" where size >= 4 && fourCC(bytes, body) == "fram":
                var lp = body + 4
                while lp + 8 <= body + size {
                    let sid = fourCC(bytes, lp)
                    let ssize = read32(bytes, lp + 4)
                    guard ssize >= 0, lp + 8 + ssize <= body + size else { break }
                    if sid == "icon" { frameBlobs.append(Array(bytes[(lp + 8)..<(lp + 8 + ssize)])) }
                    lp += 8 + ssize + (ssize & 1)
                }
            default:
                break
            }
            pos = body + size + (size & 1)
        }

        guard !frameBlobs.isEmpty else { return nil }
        let decoded = frameBlobs.map { decodeCUR($0) }
        guard let hotSpot = decoded.first(where: { $0 != nil })??.hotSpot else { return nil }

        // 'seq ' gives the playback order into the stored icons; 'rate' gives per-step durations.
        let order = sequence.isEmpty ? Array(0..<frameBlobs.count) : sequence
        var frames: [CGImage] = []
        var durations: [Double] = []
        for (step, index) in order.enumerated() {
            guard index >= 0, index < decoded.count, let frame = decoded[index] else { continue }
            frames.append(frame.image)
            let jiffies = step < rates.count ? rates[step] : defaultJiffies
            durations.append(Double(max(jiffies, 1)) / 60.0) // a "jiffy" is 1/60 s
        }
        guard let first = frames.first else { return nil }
        return DecodedCursor(
            frames: frames, frameDurations: durations, hotSpot: hotSpot,
            pixelSize: CGSize(width: first.width, height: first.height)
        )
    }

    // MARK: - .cur / .ico

    /// Decodes a single-image ICONDIR blob. `.cur` carries the hotspot in its directory entry;
    /// `.ico` has none (hotspot 0,0). A frame may hold several resolutions (HD packs store e.g.
    /// 32 and 48 px); the largest is used, with its own hotspot. ImageIO has no CUR reader, so a
    /// BMP image is re-wrapped as a single-image `.ico`, which it does read; a PNG image (used
    /// for large sizes) is a complete PNG file and is decoded directly.
    static func decodeCUR(_ bytes: [UInt8]) -> (image: CGImage, hotSpot: CGPoint)? {
        guard bytes.count >= 22, read16(bytes, 0) == 0 else { return nil }
        let type = read16(bytes, 2)
        let count = read16(bytes, 4)
        guard type == 1 || type == 2, count >= 1, 6 + 16 * count <= bytes.count else { return nil }

        // Pick the largest image in the directory.
        var best = 0
        var bestWidth = -1
        for index in 0..<count {
            let width = bytes[6 + 16 * index] == 0 ? 256 : Int(bytes[6 + 16 * index])
            if width > bestWidth {
                best = index
                bestWidth = width
            }
        }
        let entry = 6 + 16 * best
        let hotSpot = type == 2 ? CGPoint(x: read16(bytes, entry + 4), y: read16(bytes, entry + 6)) : .zero
        let imageSize = read32(bytes, entry + 8)
        let imageOffset = read32(bytes, entry + 12)
        guard imageSize > 0, imageOffset >= 0, imageOffset + imageSize <= bytes.count else { return nil }
        let payload = Array(bytes[imageOffset..<(imageOffset + imageSize)])

        let isPNG = payload.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let data: Data
        let hint: String
        if isPNG {
            data = Data(payload)
            hint = "public.png"
        } else {
            var bitCount = 32
            if payload.count >= 16, read32(payload, 0) == 40 {
                bitCount = read16(payload, 14) // BITMAPINFOHEADER.biBitCount
            }
            var ico: [UInt8] = [0, 0, 1, 0, 1, 0]                     // ICONDIR: icon, one image
            ico += Array(bytes[entry..<(entry + 4)])                  // width, height, colours, reserved
            ico += [1, 0, UInt8(bitCount & 0xff), UInt8((bitCount >> 8) & 0xff)] // planes, bit count
            ico += littleEndian32(imageSize) + littleEndian32(22)     // size, offset (6 + 16)
            data = Data(ico + payload)
            hint = "com.microsoft.ico"
        }

        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceTypeIdentifierHint: hint] as CFDictionary
        ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return (image, hotSpot)
    }

    private static func littleEndian32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    // MARK: - Byte helpers (little-endian)

    private static func read16(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    private static func read32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
    }

    private static func fourCC(_ b: [UInt8], _ o: Int) -> String {
        guard o + 4 <= b.count else { return "" }
        return String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
    }
}
