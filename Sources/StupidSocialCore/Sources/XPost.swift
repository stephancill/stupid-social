import Foundation

/// A post as chats preview it: its author, text and media (`scripts/x-web-client.py post-preview`).
public struct XPost: Hashable, Sendable {
    public struct Media: Hashable, Sendable {
        public enum Kind: Sendable {
            case photo, video, gif
        }

        public let kind: Kind
        /// The photo, or a video's poster.
        public let imageURL: URL
        public let aspectRatio: Double?
        public let videoURL: URL?
        public let durationMillis: Int?
        public let altText: String?
    }

    public let id: String
    public let authorName: String
    public let screenName: String
    public let text: String
    public let media: [Media]

    public var link: URL {
        URL(string: "https://x.com/\(screenName)/status/\(id)")!
    }

    /// The id in a link to a post on x.com or twitter.com: `/<name>/status/<id>`, `/i/status/<id>` or
    /// `/i/web/status/<id>`, with any trailing `/photo/1` and the like.
    public static func id(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              ["x.com", "twitter.com", "mobile.x.com", "mobile.twitter.com", "www.x.com", "www.twitter.com"].contains(host)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let status = parts.firstIndex(of: "status"), status + 1 < parts.count else { return nil }
        let id = parts[status + 1]
        return !id.isEmpty && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber) ? id : nil
    }
}

public extension XPost {
    /// The post as a link preview, the way Telegram shows X links: the author over the text, with photos and videos
    /// to page through in place. A post without media is a card.
    func chatEmbed(link: URL?) -> ChatEmbed {
        let title = "\(authorName) (@\(screenName))"
        let subtitle = text.isEmpty ? nil : text
        let link = link ?? self.link
        let media: [ChatEmbed] = media.map { item in
            guard let videoURL = item.videoURL else {
                return .image(url: item.imageURL, aspectRatio: item.aspectRatio, alt: item.altText, link: nil, opensViewer: true)
            }
            return .video(
                url: videoURL,
                posterURL: item.imageURL,
                aspectRatio: item.aspectRatio,
                duration: item.kind == .gif ? nil : item.durationMillis.map { XChatAdapter.duration(Int64($0)) },
                isGIF: item.kind == .gif,
            )
        }
        if media.isEmpty {
            return .card(title: title, subtitle: subtitle, systemImage: "text.bubble", imageURL: nil, link: link)
        }
        return .linkPreview(title: title, subtitle: subtitle, link: link, media: media)
    }
}

/// Maps a `TweetResultByRestId` page to an `XPost`, decoding the post as `TweetDetail` pages carry it.
enum XPostParser {
    /// Videos and GIFs play the highest-bitrate MP4 up to this, else the lowest: chat videos load whole files.
    static let maxBitrate = 1_000_000

    static func parse(data: Data) throws -> XPost? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try decoder.decode(Page.self, from: data).data?.tweetResult?.result else { return nil }
        let tweet = result.wrapped ?? result.direct
        guard let id = tweet.restId, let legacy = tweet.legacy,
              let user = tweet.core?.userResults?.result?.core, let screenName = user.screenName
        else { return nil }
        let media: [XPost.Media] = (legacy.extendedEntities?.media ?? []).compactMap { item in
            guard let imageURL = item.mediaUrlHttps.flatMap(URL.init(string:)) else { return nil }
            let kind: XPost.Media.Kind = switch item.type {
            case "video": .video
            case "animated_gif": .gif
            default: .photo
            }
            let aspectRatio = item.originalInfo.flatMap { info in
                info.width.flatMap { width in info.height.map { Double(width) / Double(max($0, 1)) } }
            }
            let variants = (item.videoInfo?.variants ?? [])
                .filter { $0.contentType == "video/mp4" && $0.url != nil }
                .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            let variant = variants.last { ($0.bitrate ?? 0) <= maxBitrate } ?? variants.first
            return XPost.Media(
                kind: kind,
                imageURL: imageURL,
                aspectRatio: aspectRatio,
                videoURL: kind == .photo ? nil : variant?.url.flatMap(URL.init(string:)),
                durationMillis: item.videoInfo?.durationMillis,
                altText: item.extAltText,
            )
        }
        return XPost(
            id: id,
            authorName: user.name ?? screenName,
            screenName: screenName,
            text: XThreadParser.text(of: tweet) ?? "",
            media: media,
        )
    }

    private struct Page: Decodable {
        let data: DataField?

        struct DataField: Decodable {
            let tweetResult: XThreadResponse.TweetResults?
        }
    }
}

/// Posts that chats link to, loaded once per account and kept for the session. Chats show a plain card until a post
/// arrives, then draw again.
@MainActor
public final class XPostResolver {
    private let load: @Sendable (String) async throws -> XPost?
    private var posts: [String: XPost] = [:]
    private var waiting: [String: [() -> Void]] = [:]
    /// Posts X has none of (deleted or protected) aren't asked for again; failed loads are, after a while.
    private var unavailable: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 300

    public init(load: @escaping @Sendable (String) async throws -> XPost?) {
        self.load = load
    }

    public convenience init(client: XClient) {
        self.init { try await client.post(id: $0) }
    }

    public func post(_ id: String) -> XPost? {
        posts[id]
    }

    /// Loads the post unless it's loaded, loading, or unavailable; `onLoad` runs once it has arrived.
    public func resolve(_ id: String, onLoad: @escaping () -> Void) {
        guard posts[id] == nil, !unavailable.contains(id),
              failedAt[id].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true
        else { return }
        if waiting[id] != nil {
            waiting[id]?.append(onLoad)
            return
        }
        waiting[id] = [onLoad]
        Task {
            do {
                if let post = try await load(id) {
                    posts[id] = post
                } else {
                    unavailable.insert(id)
                }
                failedAt[id] = nil
            } catch {
                failedAt[id] = Date()
            }
            let callbacks = waiting.removeValue(forKey: id) ?? []
            if posts[id] != nil {
                callbacks.forEach { $0() }
            }
        }
    }
}
