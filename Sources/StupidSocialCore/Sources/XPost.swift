import Foundation

/// A post as chats show it: its author, text, media and the post it quotes
/// (`scripts/x-web-client.py post-preview`).
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
    public let avatarURL: URL?
    public let isVerified: Bool
    public let postedAt: Date?
    public let text: String
    public let media: [Media]
    /// Held in an array, since a struct can't contain itself.
    private let quotedPosts: [XPost]

    public var quoted: XPost? {
        quotedPosts.first
    }

    public init(id: String, authorName: String, screenName: String, avatarURL: URL? = nil, isVerified: Bool = false, postedAt: Date? = nil, text: String, media: [Media] = [], quoted: XPost? = nil) {
        self.id = id
        self.authorName = authorName
        self.screenName = screenName
        self.avatarURL = avatarURL
        self.isVerified = isVerified
        self.postedAt = postedAt
        self.text = text
        self.media = media
        quotedPosts = quoted.map { [$0] } ?? []
    }

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
    /// The post drawn as a post: author, badge, time, the whole text, media to page through and the quoted post.
    func chatEmbed(link: URL?) -> ChatEmbed {
        .post(chatPost(link: link ?? self.link))
    }

    private func chatPost(link: URL) -> ChatPost {
        ChatPost(
            authorName: authorName,
            authorHandle: "@\(screenName)",
            authorAvatarURL: avatarURL,
            isVerified: isVerified,
            date: postedAt,
            text: text,
            media: media.map { item in
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
            },
            link: link,
            network: .x,
            quoted: quoted.map { $0.chatPost(link: $0.link) },
        )
    }
}

/// Maps a `TweetResultByRestId` page to an `XPost`, decoding the post as `TweetDetail` pages carry it.
enum XPostParser {
    /// Videos and GIFs play the highest-bitrate MP4 up to this, else the lowest: chat videos load whole files.
    static let maxBitrate = 1_000_000

    static func parse(data: Data) throws -> XPost? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Page.self, from: data).data?.tweetResult?.result.flatMap(post(from:))
    }

    private static func post(from result: XThreadResponse.Result) -> XPost? {
        let tweet = result.wrapped ?? result.direct
        guard let id = tweet.restId, let legacy = tweet.legacy, let author = tweet.core?.userResults?.result,
              let screenName = author.core?.screenName
        else { return nil }
        return XPost(
            id: id,
            authorName: author.core?.name ?? screenName,
            screenName: screenName,
            // `_normal` is 48 pixels; the card's picture is up to 108.
            avatarURL: author.avatar?.imageUrl.flatMap { URL(string: $0.replacingOccurrences(of: "_normal.", with: "_200x200.")) },
            isVerified: author.isBlueVerified == true || author.verification?.verified == true,
            postedAt: legacy.createdAt.flatMap(Date.twitter),
            text: text(of: tweet),
            media: (legacy.extendedEntities?.media ?? []).compactMap(media(from:)),
            quoted: tweet.quotedStatusResult?.result.flatMap(post(from:)),
        )
    }

    /// The shown text with its t.co links as X shows them (`display_url`), and without the link to the quoted post,
    /// which the quote shows instead.
    private static func text(of tweet: XThreadResponse.Tweet) -> String {
        var text = XThreadParser.text(of: tweet) ?? ""
        if let permalink = tweet.legacy?.quotedStatusPermalink?.url, text.hasSuffix(permalink) {
            text = String(text.dropLast(permalink.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for link in tweet.legacy?.entities?.urls ?? [] {
            guard let url = link.url, let display = link.displayUrl else { continue }
            text = text.replacingOccurrences(of: url, with: display)
        }
        return text
    }

    private static func media(from item: XThreadResponse.Media) -> XPost.Media? {
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

    private struct Page: Decodable {
        let data: DataField?

        struct DataField: Decodable {
            let tweetResult: XThreadResponse.TweetResults?
        }
    }
}

/// Posts that chats link to, loaded once per account and kept for the session. Chats show what the network sent
/// until a post arrives; `ChatKit.linksDidResolve()` then draws them again.
@MainActor
public final class XPostResolver {
    private let load: @Sendable (String) async throws -> XPost?
    private var posts: [String: XPost] = [:]
    private var loading: Set<String> = []
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

    /// Loads the post unless it's loaded, loading, or unavailable, and has chats draw again once it arrives.
    public func resolve(_ id: String) {
        guard posts[id] == nil, !unavailable.contains(id), !loading.contains(id),
              failedAt[id].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true
        else { return }
        loading.insert(id)
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
            loading.remove(id)
            if posts[id] != nil {
                ChatKit.linksDidResolve()
            }
        }
    }

    /// The embed for a link to a post, for `ChatKit.resolveLink`: the post once loaded, else nil while it loads.
    public func embed(for url: URL) -> ChatEmbed? {
        guard let id = XPost.id(in: url) else { return nil }
        if let post = posts[id] {
            return post.chatEmbed(link: url)
        }
        resolve(id)
        return nil
    }
}
