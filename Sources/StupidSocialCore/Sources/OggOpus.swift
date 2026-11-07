import AVFoundation

/// Mono Ogg Opus (RFC 7845) from an audio file, the format Telegram's apps send voice messages in. Core Audio
/// encodes Opus but writes no Ogg, so the pages are built here: an `OpusHead` page, an `OpusTags` page, then the
/// 20 ms audio packets about a second to a page.
public enum OggOpusEncoder {
    static let sampleRate = 48000.0
    static let framesPerPacket: AVAudioFrameCount = 960

    public static func encode(fileAt url: URL, bitRate: Int = 32000) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0,
        )
        guard let opus = AVAudioFormat(streamDescription: &description),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: opus)
        else { throw OggOpusError.encoderUnavailable }
        converter.bitRate = bitRate

        // The whole recording, down-mixed to its first channel; voice messages are short.
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let read = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames),
              let source = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames)
        else { throw OggOpusError.empty }
        try file.read(into: read)
        guard let readChannel = read.floatChannelData?[0], let sourceChannel = source.floatChannelData?[0] else { throw OggOpusError.empty }
        sourceChannel.update(from: readChannel, count: Int(read.frameLength))
        source.frameLength = read.frameLength

        var packets: [Data] = []
        var supplied = false
        let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 64, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            if let error { throw error }
            for index in 0 ..< Int(output.packetCount) {
                guard let packet = output.packetDescriptions?[index] else { continue }
                packets.append(Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || output.packetCount == 0 && supplied {
                break
            }
        }
        guard !packets.isEmpty else { throw OggOpusError.empty }

        let preSkip = UInt16(clamping: converter.primeInfo.leadingFrames)
        let samples = Int64((Double(source.frameLength) * sampleRate / input.sampleRate).rounded())
        return pages(packets: packets, preSkip: preSkip, samples: samples)
    }

    /// The Ogg stream for Opus packets of `framesPerPacket` each; `samples` (at 48 kHz) trims the last packet's
    /// padding through the final page's granule position.
    static func pages(packets: [Data], preSkip: UInt16, samples: Int64) -> Data {
        var head = Data("OpusHead".utf8)
        head.append(1) // version
        head.append(1) // channels
        head.appendLittleEndian(preSkip)
        head.appendLittleEndian(UInt32(sampleRate))
        head.appendLittleEndian(UInt16(0)) // output gain
        head.append(0) // channel mapping family
        var tags = Data("OpusTags".utf8)
        let vendor = Data("StupidSocial".utf8)
        tags.appendLittleEndian(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLittleEndian(UInt32(0)) // user comments

        let serial = UInt32.random(in: 1 ... .max)
        var stream = Data()
        var sequence: UInt32 = 0
        func page(_ contents: [Data], granule: Int64, flags: UInt8) {
            stream.append(OggPage.make(packets: contents, granule: granule, serial: serial, sequence: sequence, flags: flags))
            sequence += 1
        }
        page([head], granule: 0, flags: 0x02)
        page([tags], granule: 0, flags: 0)
        let end = Int64(preSkip) + samples
        var start = 0
        while start < packets.count {
            // About a second of audio, within a page's 255 lacing values.
            var stop = start
            var segments = 0
            while stop < packets.count, stop - start < 50 {
                let needed = packets[stop].count / 255 + 1
                guard segments + needed <= 255 else { break }
                segments += needed
                stop += 1
            }
            let isLast = stop == packets.count
            let granule = min(Int64(stop) * Int64(framesPerPacket), end)
            page(Array(packets[start ..< stop]), granule: isLast ? end : granule, flags: isLast ? 0x04 : 0)
            start = stop
        }
        return stream
    }
}

enum OggPage {
    static func make(packets: [Data], granule: Int64, serial: UInt32, sequence: UInt32, flags: UInt8) -> Data {
        var lacing: [UInt8] = []
        for packet in packets {
            lacing += Array(repeating: 255, count: packet.count / 255) + [UInt8(packet.count % 255)]
        }
        var page = Data("OggS".utf8)
        page.append(0) // version
        page.append(flags)
        page.appendLittleEndian(UInt64(bitPattern: granule))
        page.appendLittleEndian(serial)
        page.appendLittleEndian(sequence)
        page.appendLittleEndian(UInt32(0)) // checksum, filled in below
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        for packet in packets {
            page.append(packet)
        }
        let checksum = crc(page)
        page.replaceSubrange(22 ..< 26, with: withUnsafeBytes(of: checksum.littleEndian) { Data($0) })
        return page
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting at zero.
    static func crc(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}

public enum OggOpusError: LocalizedError {
    case encoderUnavailable
    case empty

    public var errorDescription: String? {
        switch self {
        case .encoderUnavailable: "This device can't encode the voice message."
        case .empty: "The recording is empty."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
