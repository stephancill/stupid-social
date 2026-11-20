import Foundation

/// A Bluesky post as chats draw it, loaded from the public AppView without signing in, so links draw as posts with
/// or without a Bluesky account (`scripts/bluesky-web-client.py post-preview --url <link>`).
public struct BlueskyPost: Hashable, Sendable, Codable {
    public struct Media: Hashable, Sendable, Codable {
        /// The photo, or a video's thumbnail.
        public let imageURL: URL
        /// A video's HLS playlist.
        public let videoURL: URL?
        public let aspectRatio: Double?
        public let alt: String?
    }

    public let did: String
    public let rkey: String
    public let handle: String
    public let displayName: String?
    public let avatarURL: URL?
    public let isVerified: Bool
    public let postedAt: Date?
    public let text: String
    public let media: [Media]
    public let replyCount: Int?
    public let repostCount: Int?
    public let likeCount: Int?
    /// Held in an array, since a struct can't contain itself.
    private let quotedPosts: [BlueskyPost]

    public var quoted: BlueskyPost? {
        quotedPosts.first
    }

    public var link: URL {
        URL(string: "https://bsky.app/profile/\(handle)/post/\(rkey)")!
    }

    /// The author (handle or DID) and record key in a bsky.app post link, `/profile/<actor>/post/<rkey>`.
    public static func reference(in url: URL) -> (actor: String, rkey: String)? {
        guard let host = url.host()?.lowercased(), ["bsky.app", "www.bsky.app"].contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "profile", parts[2] == "post", !parts[1].isEmpty,
              !parts[3].isEmpty, parts[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return (parts[1], parts[3])
    }

    static let appView = URL(string: "https://public.api.bsky.app/xrpc/")!

    /// The post, or nil when it's gone or its author can't be found. `getPosts` answers a handle in an at:// URI
    /// with an error, so a handle resolves to its DID first (observed 2026-11-20).
    public static func load(actor: String, rkey: String, session: URLSession = .shared) async throws -> BlueskyPost? {
        var did = actor
        if !actor.hasPrefix("did:") {
            guard let data = try await get("com.atproto.identity.resolveHandle", ["handle": actor], session: session) else { return nil }
            did = try JSONDecoder().decode(ResolvedHandle.self, from: data).did
        }
        guard let data = try await get("app.bsky.feed.getPosts", ["uris": "at://\(did)/app.bsky.feed.post/\(rkey)"], session: session)
        else { return nil }
        return try parse(data: data)
    }

    /// A 400 is the AppView saying there's no such handle or post.
    private static func get(_ method: String, _ query: [String: String], session: URLSession) async throws -> Data? {
        var components = URLComponents(url: appView.appending(path: method), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 { return nil }
        guard (200 ..< 300).contains(status) else { throw SourceError.serviceError("Bluesky request failed (HTTP \(status))") }
        return data
    }

    static func parse(data: Data) throws -> BlueskyPost? {
        try JSONDecoder().decode(PostsResponse.self, from: data).posts.first.flatMap { post(from: $0) }
    }

    private static func post(from view: PostView) -> BlueskyPost? {
        guard let rkey = view.uri.split(separator: "/").last.map(String.init) else { return nil }
        var quoted: ViewRecord?
        var media: [Media] = []
        if let embed = view.embed {
            media = embed.media ?? embed.mediaView?.media ?? []
            quoted = embed.record?.quotedPost
        }
        return BlueskyPost(
            did: view.author.did,
            rkey: rkey,
            handle: view.author.handle,
            displayName: view.author.shownName,
            avatarURL: view.author.avatar,
            isVerified: view.author.isVerified,
            postedAt: view.record.createdAt.flatMap(date),
            text: view.record.text ?? "",
            media: media,
            replyCount: view.replyCount,
            repostCount: view.repostCount,
            likeCount: view.likeCount,
            quotedPosts: quoted.flatMap(post(from:)).map { [$0] } ?? [],
        )
    }

    private static func post(from record: ViewRecord) -> BlueskyPost? {
        guard let author = record.author, let value = record.value, let rkey = record.uri?.split(separator: "/").last.map(String.init)
        else { return nil }
        return BlueskyPost(
            did: author.did,
            rkey: rkey,
            handle: author.handle,
            displayName: author.shownName,
            avatarURL: author.avatar,
            isVerified: author.isVerified,
            postedAt: value.createdAt.flatMap(date),
            text: value.text ?? "",
            media: record.embeds?.lazy.compactMap(\.media).first ?? [],
            replyCount: record.replyCount,
            repostCount: record.repostCount,
            likeCount: record.likeCount,
            quotedPosts: [],
        )
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: AppView responses

    private struct ResolvedHandle: Decodable {
        let did: String
    }

    private struct PostsResponse: Decodable {
        let posts: [PostView]
    }

    private struct PostView: Decodable {
        let uri: String
        let author: Author
        let record: Record
        let embed: EmbedView?
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
    }

    private struct Author: Decodable {
        struct Verification: Decodable {
            let verifiedStatus: String?
        }

        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
        let verification: Verification?

        var shownName: String? {
            displayName.flatMap { $0.isEmpty ? nil : $0 }
        }

        var isVerified: Bool {
            verification?.verifiedStatus == "valid"
        }
    }

    private struct Record: Decodable {
        let text: String?
        let createdAt: String?
    }

    private struct AspectRatio: Decodable {
        let width: Double
        let height: Double

        var value: Double? {
            height > 0 ? width / height : nil
        }
    }

    /// `app.bsky.embed.images#view` or `app.bsky.embed.video#view`; other embeds (link cards) have no media.
    private struct MediaView: Decodable {
        struct Image: Decodable {
            let fullsize: URL?
            let thumb: URL?
            let alt: String?
            let aspectRatio: AspectRatio?
        }

        let images: [Image]?
        let playlist: URL?
        let thumbnail: URL?
        let alt: String?
        let aspectRatio: AspectRatio?

        var media: [Media]? {
            if let images {
                let media = images.compactMap { image in
                    (image.fullsize ?? image.thumb).map { Media(imageURL: $0, videoURL: nil, aspectRatio: image.aspectRatio?.value, alt: image.alt) }
                }
                return media.isEmpty ? nil : media
            }
            if let playlist, let thumbnail {
                return [Media(imageURL: thumbnail, videoURL: playlist, aspectRatio: aspectRatio?.value, alt: alt)]
            }
            return nil
        }
    }

    /// A post's embed: media, a quoted post (`record#view`), or both (`recordWithMedia#view`, whose `media` is the
    /// media and whose `record.record` the quoted post).
    private struct EmbedView: Decodable {
        let images: [MediaView.Image]?
        let playlist: URL?
        let thumbnail: URL?
        let alt: String?
        let aspectRatio: AspectRatio?
        let record: RecordSlot?
        let mediaView: MediaView?

        enum CodingKeys: String, CodingKey {
            case images, playlist, thumbnail, alt, aspectRatio, record
            case mediaView = "media"
        }

        var media: [Media]? {
            MediaView(images: images, playlist: playlist, thumbnail: thumbnail, alt: alt, aspectRatio: aspectRatio).media
        }
    }

    /// `record#view`'s `record`: the quoted post itself (`#viewRecord`), one that's gone or blocked, or in
    /// `recordWithMedia#view` a `record#view` holding it in `record`.
    private struct RecordSlot: Decodable {
        let type: String?
        let uri: String?
        let author: Author?
        let value: Record?
        let embeds: [MediaView]?
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
        let record: ViewRecord?

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case uri, author, value, embeds, replyCount, repostCount, likeCount, record
        }

        var quotedPost: ViewRecord? {
            if type == "app.bsky.embed.record#viewRecord" {
                return ViewRecord(type: type, uri: uri, author: author, value: value, embeds: embeds, replyCount: replyCount, repostCount: repostCount, likeCount: likeCount)
            }
            return record?.type == "app.bsky.embed.record#viewRecord" ? record : nil
        }
    }

    private struct ViewRecord: Decodable {
        let type: String?
        let uri: String?
        let author: Author?
        let value: Record?
        let embeds: [MediaView]?
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case uri, author, value, embeds, replyCount, repostCount, likeCount
        }
    }
}

public extension BlueskyPost {
    /// The post as chats draw posts: author, badge, time, the text, media to page through and the quoted post.
    func chatEmbed(link: URL?) -> ChatEmbed {
        .post(chatPost(link: link ?? self.link))
    }

    private func chatPost(link: URL) -> ChatPost {
        ChatPost(
            authorName: displayName ?? handle,
            authorHandle: "@\(handle)",
            authorAvatarURL: avatarURL,
            isVerified: isVerified,
            date: postedAt,
            text: text,
            media: media.map { item in
                guard let videoURL = item.videoURL else {
                    return .image(url: item.imageURL, aspectRatio: item.aspectRatio, alt: item.alt, link: nil, opensViewer: true)
                }
                return .video(url: videoURL, posterURL: item.imageURL, aspectRatio: item.aspectRatio, duration: nil, isGIF: false)
            },
            link: link,
            network: .bluesky,
            counts: ChatPost.Counts(replies: replyCount, reposts: repostCount, likes: likeCount),
            quoted: quoted.map { $0.chatPost(link: $0.link) },
        )
    }
}
