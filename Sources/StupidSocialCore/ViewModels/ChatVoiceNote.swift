import AVFoundation

/// A voice message the user recorded, as the chat framework hands it to a `ChatVoiceSending` adapter: the
/// recording as a local audio file, with its length and waveform. The adapter turns the file into what its network
/// takes, such as Ogg Opus (`OggOpusEncoder`).
public struct ChatVoiceNote: Equatable, Sendable {
    /// A local audio file AVFoundation can read.
    public let fileURL: URL
    /// In seconds.
    public let duration: Double
    /// Levels from 0 to 1, as `ChatEmbed.voice` shows them.
    public let waveform: [Double]

    public init(fileURL: URL, duration: Double, waveform: [Double]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
    }

    /// Reads the recording for its length and a waveform of `levels` levels: each the loudest sample in its
    /// stretch of the recording, scaled so the loudest level is 1, as Telegram's apps draw them.
    public init(recordingAt url: URL, levels: Int = 100) throws {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let format = file.processingFormat
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ChatVoiceNoteError.empty
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw ChatVoiceNoteError.empty }
        let count = Int(buffer.frameLength)
        var peaks = (0 ..< levels).map { level in
            let start = level * count / levels
            let end = max(start + 1, (level + 1) * count / levels)
            var peak: Float = 0
            for index in start ..< min(end, count) {
                peak = max(peak, abs(channel[index]))
            }
            return Double(peak)
        }
        let loudest = peaks.max() ?? 0
        if loudest > 0 {
            peaks = peaks.map { $0 / loudest }
        }
        self.init(fileURL: url, duration: Double(count) / format.sampleRate, waveform: peaks)
    }
}

public enum ChatVoiceNoteError: LocalizedError {
    case empty

    public var errorDescription: String? {
        "The recording is empty."
    }
}
