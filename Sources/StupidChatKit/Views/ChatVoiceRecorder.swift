import AVFoundation

/// Records one voice message at a time for the composer: 48 kHz mono PCM to a temporary file, which
/// `ChatVoiceNote` reads for its length and waveform and the network's adapter encodes.
@MainActor
final class ChatVoiceRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Allow microphone access in Settings to record voice messages."
            case .couldNotStart: "The microphone couldn't start recording."
            }
        }
    }

    /// Shorter recordings are taken for a slip and dropped.
    static let minimumDuration: TimeInterval = 0.5
    /// The composer sends the message once it's this long.
    static let maximumDuration: TimeInterval = 15 * 60

    private var recorder: AVAudioRecorder?

    var isRecording: Bool {
        recorder != nil
    }

    var elapsed: TimeInterval {
        recorder?.currentTime ?? 0
    }

    /// Asks for the microphone the first time, then starts recording.
    func start() async throws {
        guard recorder == nil else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).caf")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.couldNotStart
        }
        self.recorder = recorder
    }

    /// Stops and returns the recording, or `nil` when it's too short to send.
    func finish() -> ChatVoiceNote? {
        guard let recorder else { return nil }
        end()
        let note = try? ChatVoiceNote(recordingAt: recorder.url)
        guard let note, note.duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return note
    }

    func cancel() {
        guard let recorder else { return }
        end()
        recorder.deleteRecording()
    }

    private func end() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
