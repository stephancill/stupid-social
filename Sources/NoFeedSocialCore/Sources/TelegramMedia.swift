import Foundation
import NoFeedSocialPush

/// Rich content in a Telegram message, kept `Codable` for the chat snapshot; the chat maps it to `ChatEmbed`.
public enum TelegramEmbed: Codable, Hashable, Sendable {
    case image(url: URL, aspectRatio: Double?)
    case card(title: String, subtitle: String?, systemImage: String, imageURL: URL?, link: URL?)
}

/// One emoji's total on a message; `isMine` when the user chose it.
public struct TelegramReaction: Codable, Hashable, Sendable {
    public let emoji: String
    public let count: Int
    public let isMine: Bool
}

/// Who reacted with what, from a message's recent reactions (Telegram sends them for small chats).
public struct TelegramReactor: Codable, Hashable, Sendable {
    public let emoji: String
    public let peerId: Int64
    public let isMine: Bool
    /// Optional so snapshots saved before it existed still decode.
    private let unread: Bool?

    public init(emoji: String, peerId: Int64, isMine: Bool, isUnread: Bool = false) {
        self.emoji = emoji
        self.peerId = peerId
        self.isMine = isMine
        unread = isUnread
    }

    /// Someone else's reaction to the user's message that the user hasn't seen.
    public var isUnread: Bool {
        unread == true
    }
}

/// `tgfile://file/<key>?dc=<dc>&loc=<InputFileLocation>`: a Telegram file any image view can load through
/// `URLSession`, since `TelegramFileURLProtocol` serves the scheme. The location is the TL-encoded
/// `InputFileLocation` (base64url), so the URL needs no lookup table; `key` names the disk cache entry.
enum TelegramMediaURL {
    static let scheme = "tgfile"
    /// Thumbnails, photos, static stickers and avatars; whole videos and files aren't downloaded.
    static let maxDownloadSize = 20 * 1024 * 1024

    static func make(key: String, dc: Int, location: TLObject) -> URL? {
        var writer = TLWriter()
        guard (try? writer.object(location)) != nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = "/" + key
        components.queryItems = [
            URLQueryItem(name: "dc", value: String(dc)),
            URLQueryItem(name: "loc", value: writer.data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")),
        ]
        return components.url
    }

    static func parse(_ url: URL) -> (key: String, dc: Int, location: TLObject)? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dc = components.queryItems?.first(where: { $0.name == "dc" })?.value.flatMap(Int.init),
              var encoded = components.queryItems?.first(where: { $0.name == "loc" })?.value
        else { return nil }
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        var reader = TLReader(data)
        guard let location = (try? reader.value(.boxed("InputFileLocation")))?.object else { return nil }
        return (String(components.path.dropFirst()), dc, location)
    }

    static func cacheName(_ key: String) -> String {
        TelegramCrypto.sha256(Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Serves `tgfile:` URLs from `TelegramClient`, so `CachedAsyncImage`, chat bubbles and the image viewer load
/// Telegram files lazily, only when shown. Registered with `register(clients:)` whenever the Telegram accounts
/// change. A URL doesn't name its account, so each signed-in account tries in turn: another account's file
/// reference fails and the next one gets it.
public final class TelegramFileURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var telegrams: [TelegramClient] = []
    private var loadTask: Task<Void, Never>?

    public static func register(clients: [TelegramClient]) {
        telegrams = clients
        URLProtocol.registerClass(TelegramFileURLProtocol.self)
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == TelegramMediaURL.scheme
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        let telegrams = Self.telegrams
        guard let url = request.url, !telegrams.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // URLProtocol's client may be called from any thread; the instance only crosses into the task.
        let loader = Loader(urlProtocol: self)
        loadTask = Task {
            var lastError: Error = URLError(.unsupportedURL)
            for telegram in telegrams {
                guard await telegram.account != nil else { continue }
                do {
                    let data = try await telegram.file(at: url)
                    Self.saveForNotifications(url: url, data: data)
                    guard !Task.isCancelled else { return }
                    loader.finish(url: url, data: data)
                    return
                } catch {
                    lastError = error
                }
            }
            loader.fail(lastError)
        }
    }

    /// User and group avatars go to the App Group too, for the notification extension to show: a private message
    /// with its sender's photo, a group message with the group's.
    private static func saveForNotifications(url: URL, data: Data) {
        guard let key = TelegramMediaURL.parse(url)?.key, key.hasPrefix("avatar-") else { return }
        let peer = key.dropFirst("avatar-".count)
        guard let colon = peer.firstIndex(of: ":"),
              let id = peer[peer.index(after: colon)...].split(separator: "-").first.flatMap({ Int64($0) })
        else { return }
        switch peer[..<colon] {
        case "user": TelegramAvatarStore().save(data, userId: id)
        case "chat", "channel": TelegramAvatarStore().save(data, groupId: id)
        default: break
        }
    }

    private struct Loader: @unchecked Sendable {
        let urlProtocol: TelegramFileURLProtocol

        func finish(url: URL, data: Data) {
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data)
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }

        func fail(_ error: Error) {
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: error)
        }
    }

    override public func stopLoading() {
        loadTask?.cancel()
    }
}

/// Telegram media and reactions as the app shows them.
enum TelegramMediaParser {
    /// The largest photo size whose long side is at most `maxSide`, else the smallest larger one.
    static func bestSize(_ sizes: [TLObject], maxSide: Int32 = 1280) -> (type: String, width: Int32, height: Int32)? {
        let candidates = sizes.compactMap { size -> (String, Int32, Int32)? in
            guard ["photoSize", "photoSizeProgressive", "photoCachedSize"].contains(size.name),
                  let type = size["type"]?.string, let w = size["w"]?.int, let h = size["h"]?.int
            else { return nil }
            return (type, w, h)
        }
        let fitting = candidates.filter { max($0.1, $0.2) <= maxSide }
        if let best = fitting.max(by: { $0.1 * $0.2 < $1.1 * $1.2 }) {
            return best
        }
        return candidates.min { $0.1 * $0.2 < $1.1 * $1.2 }
    }

    static func photoURL(_ photo: TLObject, maxSide: Int32 = 1280) -> (url: URL, aspectRatio: Double)? {
        guard photo.name == "photo", let id = photo["id"]?.long, let accessHash = photo["access_hash"]?.long,
              let reference = photo["file_reference"]?.bytes, let dc = photo["dc_id"]?.int,
              let size = bestSize(photo.objects("sizes"), maxSide: maxSide)
        else { return nil }
        let location = TLObject("inputPhotoFileLocation", ["id": .long(id), "access_hash": .long(accessHash), "file_reference": .bytes(reference), "thumb_size": .string(size.type)])
        guard let url = TelegramMediaURL.make(key: "photo-\(id)-\(size.type)", dc: Int(dc), location: location) else { return nil }
        return (url, Double(size.width) / Double(max(size.height, 1)))
    }

    /// A document's thumbnail, or the whole document when `thumbSize` is empty (static stickers).
    static func documentURL(_ document: TLObject, thumbSize: String) -> URL? {
        guard let id = document["id"]?.long, let accessHash = document["access_hash"]?.long,
              let reference = document["file_reference"]?.bytes, let dc = document["dc_id"]?.int
        else { return nil }
        let location = TLObject("inputDocumentFileLocation", ["id": .long(id), "access_hash": .long(accessHash), "file_reference": .bytes(reference), "thumb_size": .string(thumbSize)])
        return TelegramMediaURL.make(key: "document-\(id)-\(thumbSize.isEmpty ? "full" : thumbSize)", dc: Int(dc), location: location)
    }

    /// A user's or chat's small profile photo, through `inputPeer` (which may be `inputPeerUserFromMessage`).
    static func avatarURL(photo: TLObject?, inputPeer: TLObject, key: String) -> URL? {
        guard let photo, let photoId = photo["photo_id"]?.long, let dc = photo["dc_id"]?.int else { return nil }
        let location = TLObject("inputPeerPhotoFileLocation", ["peer": .object(inputPeer), "photo_id": .long(photoId)])
        return TelegramMediaURL.make(key: "avatar-\(key)-\(photoId)", dc: Int(dc), location: location)
    }

    /// What a message's media shows: embeds, and a one-line label for previews and media without a picture.
    static func content(of media: TLObject) -> (label: String?, embeds: [TelegramEmbed]) {
        switch media.name {
        case "messageMediaPhoto":
            guard let photo = media["photo"]?.object, let image = photoURL(photo) else { return ("Photo", []) }
            return ("Photo", [.image(url: image.url, aspectRatio: image.aspectRatio)])
        case "messageMediaDocument":
            guard let document = media["document"]?.object else { return ("File", []) }
            return documentContent(document)
        case "messageMediaWebPage":
            guard let page = media["webpage"]?.object, page.name == "webPage" else { return (nil, []) }
            let title = [page["title"]?.string, page["site_name"]?.string, page["display_url"]?.string].compactMap(\.self).first { !$0.isEmpty } ?? "Link"
            let subtitle = [page["description"]?.string, page["site_name"]?.string].compactMap(\.self).first { !$0.isEmpty && $0 != title }
            return (nil, [.card(
                title: title,
                subtitle: subtitle.map { String($0.prefix(160)) },
                systemImage: "link",
                imageURL: page["photo"]?.object.flatMap { photoURL($0, maxSide: 320)?.url },
                link: page["url"]?.string.flatMap(URL.init),
            )])
        case "messageMediaGeo", "messageMediaGeoLive", "messageMediaVenue":
            let point = media["geo"]?.object
            let link = point.flatMap { point -> URL? in
                guard let lat = point["lat"].flatMap({ if case let .double(v) = $0 { v } else { nil } }),
                      let long = point["long"].flatMap({ if case let .double(v) = $0 { v } else { nil } })
                else { return nil }
                return URL(string: "https://maps.apple.com/?ll=\(lat),\(long)")
            }
            let title = media["title"]?.string ?? "Location"
            return ("Location", [.card(title: title, subtitle: media["address"]?.string, systemImage: "mappin.and.ellipse", imageURL: nil, link: link)])
        case "messageMediaContact":
            let name = [media["first_name"]?.string, media["last_name"]?.string].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
            return ("Contact", [.card(title: name.isEmpty ? "Contact" : name, subtitle: media["phone_number"]?.string, systemImage: "person.crop.circle", imageURL: nil, link: nil)])
        case "messageMediaPoll":
            let question = media["poll"]?.object?["question"]?.object?["text"]?.string
            return ("Poll", [.card(title: question ?? "Poll", subtitle: "Poll", systemImage: "chart.bar", imageURL: nil, link: nil)])
        case "messageMediaDice":
            return (media["emoticon"]?.string ?? "🎲", [])
        case "messageMediaGame": return ("Game", [])
        case "messageMediaInvoice": return ("Invoice", [])
        case "messageMediaStory": return ("Story", [])
        case "messageMediaGiveaway", "messageMediaGiveawayResults": return ("Giveaway", [])
        case "messageMediaEmpty": return (nil, [])
        default: return ("Attachment", [])
        }
    }

    private static func documentContent(_ document: TLObject) -> (label: String?, embeds: [TelegramEmbed]) {
        let attributes = document.objects("attributes")
        let mime = document["mime_type"]?.string ?? ""
        let thumb = bestSize(document.objects("thumbs"), maxSide: 640)
        let thumbURL = thumb.flatMap { documentURL(document, thumbSize: $0.type) }
        func duration(_ seconds: Double?) -> String? {
            guard let seconds, seconds > 0 else { return nil }
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        if let sticker = attributes.first(where: { $0.name == "documentAttributeSticker" }) {
            let label = [sticker["alt"]?.string, "Sticker"].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
            let size = attributes.first { $0.name == "documentAttributeImageSize" || $0.name == "documentAttributeVideo" }
            let aspect = size.flatMap { size in size["w"]?.int.flatMap { w in size["h"]?.int.map { Double(w) / Double(max($0, 1)) } } } ?? 1
            // Static WebP stickers load whole; animated (TGS) and video (WebM) ones show their thumbnail.
            if mime == "image/webp", let url = documentURL(document, thumbSize: "") {
                return (label, [.image(url: url, aspectRatio: aspect)])
            }
            if let thumbURL {
                return (label, [.image(url: thumbURL, aspectRatio: aspect)])
            }
            return (label, [])
        }
        let video = attributes.first { $0.name == "documentAttributeVideo" }
        let isGIF = attributes.contains { $0.name == "documentAttributeAnimated" }
        if let video {
            let seconds = video["duration"].flatMap { if case let .double(v) = $0 { v } else { nil } }
            let label = isGIF ? "GIF" : video.flag("round_message") ? "Video message" : "Video"
            if isGIF, let thumbURL {
                let aspect = video["w"]?.int.flatMap { w in video["h"]?.int.map { Double(w) / Double(max($0, 1)) } }
                return (label, [.image(url: thumbURL, aspectRatio: aspect)])
            }
            return (label, [.card(title: label, subtitle: duration(seconds), systemImage: "play.rectangle", imageURL: thumbURL, link: nil)])
        }
        if let audio = attributes.first(where: { $0.name == "documentAttributeAudio" }) {
            let seconds = audio["duration"]?.int.map(Double.init)
            if audio.flag("voice") {
                return ("Voice message", [.card(title: "Voice message", subtitle: duration(seconds), systemImage: "waveform", imageURL: nil, link: nil)])
            }
            let title = audio["title"]?.string ?? "Audio"
            let subtitle = [audio["performer"]?.string, duration(seconds)].compactMap(\.self).joined(separator: " · ")
            return (title, [.card(title: title, subtitle: subtitle.isEmpty ? nil : subtitle, systemImage: "music.note", imageURL: thumbURL, link: nil)])
        }
        if isGIF, let thumbURL {
            return ("GIF", [.image(url: thumbURL, aspectRatio: nil)])
        }
        let name = attributes.first { $0.name == "documentAttributeFilename" }?["file_name"]?.string ?? "File"
        let size = document["size"]?.long.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        // Images sent as files show as images when small enough to download.
        if mime.hasPrefix("image/"), mime != "image/svg+xml", (document["size"]?.long ?? .max) <= Int64(TelegramMediaURL.maxDownloadSize),
           let url = documentURL(document, thumbSize: "")
        {
            let imageSize = attributes.first { $0.name == "documentAttributeImageSize" }
            let aspect = imageSize.flatMap { size in size["w"]?.int.flatMap { w in size["h"]?.int.map { Double(w) / Double(max($0, 1)) } } }
            return ("Photo", [.image(url: url, aspectRatio: aspect)])
        }
        return (name, [.card(title: name, subtitle: size, systemImage: "doc", imageURL: thumbURL, link: nil)])
    }

    /// Emoji reaction totals; custom-emoji and paid reactions show as ⭐️, since the app can't draw them.
    static func reactions(of message: TLObject) -> (totals: [TelegramReaction], reactors: [TelegramReactor]) {
        guard let reactions = message["reactions"]?.object else { return ([], []) }
        let totals = reactions.objects("results").compactMap { result -> TelegramReaction? in
            guard let reaction = result["reaction"]?.object, let count = result["count"]?.int else { return nil }
            return TelegramReaction(emoji: emoji(reaction), count: Int(count), isMine: result["chosen_order"] != nil)
        }
        let reactors = reactions.objects("recent_reactions").compactMap { recent -> TelegramReactor? in
            guard let reaction = recent["reaction"]?.object, let peer = recent["peer_id"]?.object else { return nil }
            let id = peer["user_id"]?.long ?? peer["channel_id"]?.long ?? peer["chat_id"]?.long ?? 0
            return TelegramReactor(emoji: emoji(reaction), peerId: id, isMine: recent.flag("my"), isUnread: recent.flag("unread"))
        }
        return (totals, reactors)
    }

    private static func emoji(_ reaction: TLObject) -> String {
        reaction.name == "reactionEmoji" ? reaction["emoticon"]?.string ?? "⭐️" : "⭐️"
    }
}
