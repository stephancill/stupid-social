import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Where a forwarded message came from, as its header reads: "Forwarded from <name>", or "Forwarded" when the
/// network doesn't say.
public struct ChatForwardOrigin: Hashable, Sendable {
    public let name: String?

    public init(name: String?) {
        self.name = name
    }

    public var label: String {
        name.map { "Forwarded from \($0)" } ?? "Forwarded"
    }
}

/// A message the user is forwarding to another chat, as the chat it came from describes it. In a chat on the
/// same account of the same network, a `ChatForwarding` adapter forwards it natively from `reference`; anywhere
/// else the framework sends a copy of its content (`ChatForwardCopy`).
public struct ChatForward: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let message: ChatMessage
    public let network: SocialNetwork
    public let accountId: String
    /// The source network's reference to the message for a native forward; `nil` when it can't forward natively.
    public let reference: String?
    /// Whom a copy names as its origin: the person the message was forwarded from, else its sender; `nil` for the
    /// user's own message, which the recipient would otherwise read as "You".
    public let originName: String?
    /// The message's media as local or fetchable files, in order, for a copy.
    public let media: [ChatForwardMedia]

    public init(message: ChatMessage, network: SocialNetwork, accountId: String, reference: String?, media: [ChatForwardMedia]) {
        id = UUID()
        self.message = message
        self.network = network
        self.accountId = accountId
        self.reference = reference
        originName = message.forwardedFrom.map(\.name) ?? (message.isOwn ? nil : message.sender.name)
        self.media = media
    }

    /// Whether anything of the message can be copied to another network: its text or a file.
    public var isCopyable: Bool {
        !(message.text ?? "").isEmpty || !media.isEmpty
    }
}

/// A file of a forwarded message, which a copy uploads again.
public enum ChatForwardMedia: Hashable, Sendable {
    case image(url: URL)
    case video(url: URL)
    case file(url: URL, filename: String)
    case voice(url: URL, duration: Double?, waveform: [Double])

    public var url: URL {
        switch self {
        case let .image(url), let .video(url), let .file(url, _), let .voice(url, _, _): url
        }
    }

    /// The media of embeds that have a file to fetch; cards, link previews, track shares and stickers have none.
    /// A voice message's file comes from `voiceURL`.
    @MainActor public static func from(_ embeds: [ChatEmbed], voiceURL: (String) async -> URL?) async -> [ChatForwardMedia] {
        var media: [ChatForwardMedia] = []
        for embed in embeds {
            switch embed {
            case let .image(url, _, _, _, _):
                media.append(.image(url: url))
            case let .video(url, _, _, _, _):
                media.append(.video(url: url))
            case let .file(url, filename, _, _):
                media.append(.file(url: url, filename: filename))
            case let .voice(previewId, duration, waveform):
                if let url = await voiceURL(previewId) {
                    media.append(.voice(url: url, duration: duration, waveform: waveform))
                }
            case .sticker, .card, .audio, .message, .pending:
                break
            }
        }
        return media
    }
}

/// Forwarding natively, as the network marks forwarded messages. A message forwards natively to chats on the same
/// account of the same network; everywhere else the framework sends a copy.
@MainActor
public protocol ChatForwarding: ChatAdapter {
    /// What `forward(_:)` in another of the account's chats needs to forward the message, or `nil` when the network
    /// can't forward it, such as a message still sending.
    func forwardReference(for message: ChatMessage) -> String?
    /// Forwards the message another chat of this account named, into this chat; returns the forwarded copy's id, as
    /// `send(_:)` does.
    func forward(reference: String) async throws -> String?
}

/// The messages that make up a copy of a forwarded message: "Forwarded" in italics (where the network formats
/// text) and the text first, with the first file, then each other file on its own. The copy names neither the
/// sender nor the network it came from.
enum ChatForwardCopy {
    struct Part {
        var text: String
        var media: ChatForwardMedia?
        var italics: [NSRange] = []
    }

    static let header = "Forwarded"

    static func parts(of forward: ChatForward) -> [Part] {
        let text = forward.message.text.map { $0.isEmpty ? header : "\(header)\n\n\($0)" } ?? header
        var parts = [Part(text: text, media: forward.media.first, italics: [NSRange(location: 0, length: (header as NSString).length)])]
        for media in forward.media.dropFirst() {
            parts.append(Part(text: "", media: media))
        }
        return parts
    }

    /// The file as an attachment, fetched through `ChatMediaFiles` (which serves the networks' own schemes).
    static func attachment(for media: ChatForwardMedia) async throws -> ChatAttachment {
        let filename: String? = switch media {
        case let .file(_, filename): filename
        default: nil
        }
        let local = try await ChatMediaFiles.shared.file(for: media.url, filename: filename)
        let data = try Data(contentsOf: local)
        let type = UTType(filenameExtension: local.pathExtension)
        let isImage = if case .image = media { true } else { false }
        let mimeType = type?.preferredMIMEType ?? (isImage ? "image/jpeg" : "application/octet-stream")
        return ChatAttachment(data: data, mimeType: mimeType, filename: local.lastPathComponent, isImage: isImage)
    }

    /// The voice message as a recording a `ChatVoiceSending` adapter can encode, or `nil` when AVFoundation can't
    /// read its file (such as Ogg Opus), which then goes as a file.
    static func voiceNote(for media: ChatForwardMedia) async throws -> ChatVoiceNote? {
        guard case let .voice(url, duration, waveform) = media else { return nil }
        let local = try await ChatMediaFiles.shared.file(for: url)
        guard (try? AVAudioFile(forReading: local)) != nil else { return nil }
        if let duration, !waveform.isEmpty {
            return ChatVoiceNote(fileURL: local, duration: duration, waveform: waveform)
        }
        return try ChatVoiceNote(recordingAt: local)
    }
}

/// A recording as an attachment, for networks without voice messages: AAC in an M4A file, which every network's
/// players read.
enum ChatVoiceFile {
    static func attachment(for voice: ChatVoiceNote) async throws -> ChatAttachment {
        if voice.fileURL.pathExtension.lowercased() == "m4a" {
            return try ChatAttachment(data: Data(contentsOf: voice.fileURL), mimeType: "audio/mp4", filename: "Voice Message.m4a", isImage: false)
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: voice.fileURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ChatVoiceFileError.notExportable
        }
        try await export.export(to: output, as: .m4a)
        return try ChatAttachment(data: Data(contentsOf: output), mimeType: "audio/mp4", filename: "Voice Message.m4a", isImage: false)
    }
}

enum ChatForwardError: LocalizedError {
    case noAttachments

    var errorDescription: String? {
        "This chat can't take photos or files."
    }
}

enum ChatVoiceFileError: LocalizedError {
    case notExportable

    var errorDescription: String? {
        "The recording couldn't be converted to send as a file."
    }
}
