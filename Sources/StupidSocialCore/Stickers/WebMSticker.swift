import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// A video sticker (Telegram's WebM stickers): VP9 frames, each with its alpha as a second VP9 frame in the block's
/// additions (`AlphaMode` 1), read from the WebM container here and decoded with VideoToolbox's VP9 decoder, which
/// iOS 26.2 lets apps register (`VTRegisterSupplementalVideoDecoderIfAvailable`). Earlier systems have no VP9
/// decoder for apps, so `init` fails there and the sticker shows its still.
///
/// The parsed file is shared; each `WebMStickerDecoder` keeps its own decoding state, since VP9 frames depend on the
/// ones before them.
public final class WebMSticker: Sendable {
    struct Frame {
        let data: Data
        let alpha: Data?
        let isKeyframe: Bool
        /// In the track's timecode units (milliseconds by default).
        let time: Int64
    }

    public let width: Int
    public let height: Int
    public let frameRate: Double
    let frames: [Frame]

    public var frameCount: Int {
        frames.count
    }

    public init?(data: Data) {
        guard WebMSticker.registerDecoder(), let parsed = WebMParser(data: data).parse(), !parsed.frames.isEmpty else { return nil }
        width = parsed.width
        height = parsed.height
        frames = parsed.frames
        frameRate = parsed.frameRate
    }

    /// Whether the system lets apps decode VP9; whether it actually can shows when a session is made.
    private static let registered: Bool = {
        guard #available(iOS 26.2, macOS 11.0, *) else { return false }
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        return true
    }()

    static func registerDecoder() -> Bool {
        registered
    }
}

/// Decodes one `WebMSticker`'s frames in order, restarting from the first frame when asked for an earlier one
/// (a loop). Not for use from two threads at once.
public final class WebMStickerDecoder: @unchecked Sendable {
    public let sticker: WebMSticker
    private var color: VP9Session?
    private var alpha: VP9Session?
    private var next = 0
    private var last: CGImage?
    private let lock = NSLock()

    public init?(sticker: WebMSticker) {
        self.sticker = sticker
        guard let color = VP9Session(width: sticker.width, height: sticker.height, pixelFormat: kCVPixelFormatType_32BGRA) else { return nil }
        self.color = color
        if sticker.frames.contains(where: { $0.alpha != nil }) {
            alpha = VP9Session(width: sticker.width, height: sticker.height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
    }

    /// Frame `index`, premultiplied BGRA at the video's size; frames between the last one and it are decoded and
    /// dropped.
    public func image(frame index: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let index = min(max(index, 0), sticker.frames.count - 1)
        if index == next - 1, let last {
            return last
        }
        if index < next {
            next = 0
        }
        // Decoding starts again from the frame's keyframe when a jump passes it.
        if let keyframe = sticker.frames[...index].lastIndex(where: \.isKeyframe), keyframe > next {
            next = keyframe
        }
        var colorBuffer: CVPixelBuffer?
        var alphaBuffer: CVPixelBuffer?
        while next <= index {
            let frame = sticker.frames[next]
            colorBuffer = color?.decode(frame.data)
            alphaBuffer = frame.alpha.flatMap { alpha?.decode($0) }
            next += 1
        }
        guard let colorBuffer else { return last }
        last = Self.image(color: colorBuffer, alpha: alphaBuffer) ?? last
        return last
    }

    /// The colour frame with the alpha frame's luma as its alpha, premultiplied.
    private static func image(color: CVPixelBuffer, alpha: CVPixelBuffer?) -> CGImage? {
        CVPixelBufferLockBaseAddress(color, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(color, .readOnly) }
        let width = CVPixelBufferGetWidth(color), height = CVPixelBufferGetHeight(color)
        guard let source = CVPixelBufferGetBaseAddress(color)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(color)
        let stride = width * 4
        var pixels = Data(count: stride * height)
        if let alpha {
            CVPixelBufferLockBaseAddress(alpha, .readOnly)
        }
        defer {
            if let alpha { CVPixelBufferUnlockBaseAddress(alpha, .readOnly) }
        }
        let alphaPlane = alpha.flatMap { CVPixelBufferGetBaseAddressOfPlane($0, 0)?.assumingMemoryBound(to: UInt8.self) }
        let alphaStride = alpha.map { CVPixelBufferGetBytesPerRowOfPlane($0, 0) } ?? 0
        let alphaWidth = alpha.map { CVPixelBufferGetWidthOfPlane($0, 0) } ?? 0
        let alphaHeight = alpha.map { CVPixelBufferGetHeightOfPlane($0, 0) } ?? 0
        pixels.withUnsafeMutableBytes { buffer in
            let out = buffer.bindMemory(to: UInt8.self).baseAddress!
            for y in 0 ..< height {
                let row = source + y * sourceStride
                let target = out + y * stride
                for x in 0 ..< width {
                    let a: UInt16 = if let alphaPlane, x < alphaWidth, y < alphaHeight { UInt16(alphaPlane[y * alphaStride + x]) } else { 255 }
                    target[x * 4] = UInt8(UInt16(row[x * 4]) * a / 255)
                    target[x * 4 + 1] = UInt8(UInt16(row[x * 4 + 1]) * a / 255)
                    target[x * 4 + 2] = UInt8(UInt16(row[x * 4 + 2]) * a / 255)
                    target[x * 4 + 3] = UInt8(a)
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )
    }
}

/// One VP9 stream's decompression session.
private final class VP9Session {
    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription

    init?(width: Int, height: Int, pixelFormat: OSType) {
        // A `vpcC` box (VP Codec Configuration, version 1): profile 0, level 3.1, 8-bit 4:2:0, studio range, BT.601,
        // what stickers that leave the colour space unspecified mean (ffprobe: `tv,unknown`).
        let vpcC = Data([1, 0, 0, 0, 0, 31, 0x82, 6, 6, 6, 0, 0])
        var format: CMVideoFormatDescription?
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcC]] as CFDictionary
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_VP9, width: Int32(width), height: Int32(height), extensions: extensions, formatDescriptionOut: &format) == noErr,
              let format
        else { return nil }
        let attributes = [kCVPixelBufferPixelFormatTypeKey: pixelFormat] as CFDictionary
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session
        else { return nil }
        self.session = session
        self.format = format
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    /// The frame's picture, or `nil` for a frame that isn't shown or fails.
    func decode(_ data: Data) -> CVPixelBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block
        else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample
        else { return nil }
        var output: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr {
                output = image
            }
        }
        return status == noErr ? output : nil
    }
}

/// Reads the frames of a WebM file's first VP9 track: the EBML elements down to each cluster's blocks, with the
/// alpha frame from a `BlockGroup`'s `BlockAdditions` (`BlockAddID` 1).
private struct WebMParser {
    let data: Data

    struct Result {
        var width = 0
        var height = 0
        var frameRate = 30.0
        var frames: [WebMSticker.Frame] = []
    }

    private enum ID {
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let codecID: UInt32 = 0x86
        static let defaultDuration: UInt32 = 0x23E383
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let cluster: UInt32 = 0x1F43_B675
        static let timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        static let blockAdditions: UInt32 = 0x75A1
        static let blockMore: UInt32 = 0xA6
        static let blockAddID: UInt32 = 0xEE
        static let blockAdditional: UInt32 = 0xA5
    }

    func parse() -> Result? {
        let bytes = [UInt8](data)
        var result = Result()
        var track: UInt64?
        var timecodeScale = 1_000_000.0
        var duration: Double?
        var defaultDuration: Double?
        var clusterTime: Int64 = 0

        /// The elements in `range`: id, payload range. A payload of unknown size runs to the end of `range`.
        func elements(_ range: Range<Int>) -> [(id: UInt32, payload: Range<Int>)] {
            var list: [(UInt32, Range<Int>)] = []
            var offset = range.lowerBound
            while offset < range.upperBound {
                guard let (id, idLength) = vint(bytes, at: offset, keepMarker: true),
                      let (size, sizeLength) = vint(bytes, at: offset + idLength, keepMarker: false)
                else { break }
                let start = offset + idLength + sizeLength
                let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
                let end = unknown ? range.upperBound : min(start + Int(clamping: size), range.upperBound)
                guard start <= end else { break }
                list.append((UInt32(truncatingIfNeeded: id), start ..< end))
                offset = end
            }
            return list
        }
        func uint(_ range: Range<Int>) -> UInt64 {
            bytes[range].reduce(0) { $0 << 8 | UInt64($1) }
        }
        func float(_ range: Range<Int>) -> Double {
            let value = uint(range)
            return range.count == 4 ? Double(Float(bitPattern: UInt32(value))) : Double(bitPattern: value)
        }
        /// A block's frame for our track: after the track number, a 16-bit timecode and flags.
        /// A `SimpleBlock` flags keyframes; a `BlockGroup` is one when it references no other block.
        func frame(_ range: Range<Int>, alpha: Data?, isSimple: Bool, isKeyframe: Bool = false) -> WebMSticker.Frame? {
            guard let (number, length) = vint(bytes, at: range.lowerBound, keepMarker: false), number == track else { return nil }
            let header = range.lowerBound + length
            guard header + 3 <= range.upperBound else { return nil }
            let flags = bytes[header + 2]
            // Video tracks aren't laced; a laced block isn't one frame.
            guard flags & 0x06 == 0 else { return nil }
            let relative = Int16(bitPattern: UInt16(bytes[header]) << 8 | UInt16(bytes[header + 1]))
            return WebMSticker.Frame(
                data: data.subdata(in: data.startIndex + header + 3 ..< data.startIndex + range.upperBound),
                alpha: alpha,
                isKeyframe: isSimple ? flags & 0x80 != 0 : isKeyframe,
                time: clusterTime + Int64(relative),
            )
        }

        guard let segment = elements(0 ..< bytes.count).first(where: { $0.id == ID.segment }) else { return nil }
        for (id, payload) in elements(segment.payload) {
            switch id {
            case ID.info:
                for (id, payload) in elements(payload) {
                    if id == ID.timecodeScale { timecodeScale = Double(uint(payload)) }
                    if id == ID.duration { duration = float(payload) }
                }
            case ID.tracks:
                for (id, entry) in elements(payload) where id == ID.trackEntry && track == nil {
                    let fields = elements(entry)
                    guard let codec = fields.first(where: { $0.id == ID.codecID }), String(decoding: bytes[codec.payload], as: UTF8.self) == "V_VP9",
                          let number = fields.first(where: { $0.id == ID.trackNumber })
                    else { continue }
                    track = uint(number.payload)
                    if let value = fields.first(where: { $0.id == ID.defaultDuration }) {
                        defaultDuration = Double(uint(value.payload))
                    }
                    for (id, payload) in fields.first(where: { $0.id == ID.video }).map({ elements($0.payload) }) ?? [] {
                        if id == ID.pixelWidth { result.width = Int(uint(payload)) }
                        if id == ID.pixelHeight { result.height = Int(uint(payload)) }
                    }
                }
            case ID.cluster:
                guard track != nil else { continue }
                for (id, payload) in elements(payload) {
                    if id == ID.timecode {
                        clusterTime = Int64(uint(payload))
                    } else if id == ID.simpleBlock, let frame = frame(payload, alpha: nil, isSimple: true) {
                        result.frames.append(frame)
                    } else if id == ID.blockGroup {
                        let fields = elements(payload)
                        let alpha = fields.first { $0.id == ID.blockAdditions }.flatMap { additions in
                            elements(additions.payload).filter { $0.id == ID.blockMore }.compactMap { more -> Data? in
                                let fields = elements(more.payload)
                                let addId = fields.first { $0.id == ID.blockAddID }.map { uint($0.payload) } ?? 1
                                guard addId == 1, let additional = fields.first(where: { $0.id == ID.blockAdditional }) else { return nil }
                                return data.subdata(in: data.startIndex + additional.payload.lowerBound ..< data.startIndex + additional.payload.upperBound)
                            }.first
                        }
                        let isKeyframe = !fields.contains { $0.id == ID.referenceBlock }
                        if let block = fields.first(where: { $0.id == ID.block }), let frame = frame(block.payload, alpha: alpha, isSimple: false, isKeyframe: isKeyframe) {
                            result.frames.append(frame)
                        }
                    }
                }
            default:
                break
            }
        }
        guard result.width > 0, result.height > 0 else { return nil }
        // Sticker tools write a placeholder `Duration` (1 ms, observed 2026-11-04), so the frames' own times come first.
        let times = result.frames.map(\.time)
        if let first = times.min(), let last = times.max(), last > first, times.count > 1 {
            result.frameRate = Double(times.count - 1) / (Double(last - first) * timecodeScale / 1_000_000_000)
        } else if let defaultDuration, defaultDuration > 0 {
            result.frameRate = 1_000_000_000 / defaultDuration
        } else if let duration, duration > 0, !result.frames.isEmpty {
            result.frameRate = Double(result.frames.count) / (duration * timecodeScale / 1_000_000_000)
        }
        result.frameRate = min(max(result.frameRate, 1), 60)
        return result
    }

    /// An EBML variable-length integer: its value (with or without the length marker bit) and its length.
    private func vint(_ bytes: [UInt8], at offset: Int, keepMarker: Bool) -> (UInt64, Int)? {
        guard offset < bytes.count, bytes[offset] != 0 else { return nil }
        let length = bytes[offset].leadingZeroBitCount + 1
        guard offset + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? bytes[offset] : bytes[offset] & (0xFF >> length))
        for index in 1 ..< length {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return (value, length)
    }
}
