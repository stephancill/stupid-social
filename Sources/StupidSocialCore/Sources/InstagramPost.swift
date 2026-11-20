import Foundation

/// An Instagram post as chats draw it: its author, caption, photos and videos and counts
/// (`scripts/instagram-web-client.py post-preview <shortcode>`).
public struct InstagramPost: Hashable, Sendable, Codable {
    public struct Media: Hashable, Sendable, Codable {
        /// The photo, or a video's poster.
        public let imageURL: URL
        public let videoURL: URL?
        public let aspectRatio: Double?
        public let durationSeconds: Double?
    }

    public let shortcode: String
    public let username: String
    public let fullName: String?
    public let avatarURL: URL?
    public let isVerified: Bool
    public let postedAt: Date?
    public let caption: String
    public let media: [Media]
    public let commentCount: Int?
    /// Nil when the author hides likes.
    public let likeCount: Int?

    public var link: URL {
        URL(string: "https://www.instagram.com/p/\(shortcode)/")!
    }

    /// The shortcode in a link to a post: `/p/<code>`, `/reel/<code>`, `/reels/<code>` or `/tv/<code>`, also after a
    /// username (`/<name>/p/<code>`).
    public static func shortcode(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(), ["instagram.com", "www.instagram.com", "m.instagram.com"].contains(host)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let kind = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), kind + 1 < parts.count else { return nil }
        let code = parts[kind + 1]
        return code.count >= 6 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ? code : nil
    }

    /// A post's media id: its shortcode read as base 64 in Instagram's alphabet. Codes of private posts are longer;
    /// the id is in their first 11 characters.
    static func mediaId(shortcode: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var value: UInt64 = 0
        for character in shortcode.prefix(11) {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 64)
            guard !overflow else { return nil }
            value = shifted + UInt64(digit)
        }
        return String(value)
    }

    init?(item: InstagramMediaInfoItem, shortcode: String) {
        guard let user = item.user, let username = user.username else { return nil }
        let items = item.carouselMedia?.isEmpty == false ? item.carouselMedia ?? [] : [item]
        let media = items.compactMap { entry -> Media? in
            guard let imageURL = entry.bestImageURLs.first else { return nil }
            let ratio = entry.originalWidth.flatMap { width in entry.originalHeight.map { Double(width) / Double(max($0, 1)) } }
            return Media(imageURL: imageURL, videoURL: entry.mediaType == 2 ? entry.bestVideoURL : nil, aspectRatio: ratio, durationSeconds: entry.videoDuration)
        }
        self.shortcode = item.code ?? shortcode
        self.username = username
        fullName = user.fullName.flatMap { $0.isEmpty ? nil : $0 }
        avatarURL = user.profilePicUrl.flatMap(URL.init(string:))
        isVerified = user.isVerified ?? false
        postedAt = item.takenAt.map { Date(timeIntervalSince1970: $0) }
        caption = item.caption?.text ?? ""
        self.media = media
        commentCount = item.commentCount
        likeCount = item.likeAndViewCountsDisabled == true ? nil : item.likeCount
    }

    static func parse(data: Data, shortcode: String) throws -> InstagramPost? {
        try JSONDecoder().decode(InstagramMediaInfoResponse.self, from: data).items.first.flatMap { InstagramPost(item: $0, shortcode: shortcode) }
    }
}

public extension InstagramPost {
    /// The post as chats draw posts: author, badge, time, the caption, media to page through and the counts.
    func chatEmbed(link: URL?) -> ChatEmbed {
        .post(ChatPost(
            authorName: fullName ?? username,
            authorHandle: "@\(username)",
            authorAvatarURL: avatarURL,
            isVerified: isVerified,
            date: postedAt,
            text: caption,
            media: media.map { item in
                guard let videoURL = item.videoURL else {
                    return .image(url: item.imageURL, aspectRatio: item.aspectRatio, alt: nil, link: nil, opensViewer: true)
                }
                return .video(
                    url: videoURL,
                    posterURL: item.imageURL,
                    aspectRatio: item.aspectRatio,
                    duration: item.durationSeconds.map { XChatAdapter.duration(Int64($0 * 1000)) },
                    isGIF: false,
                )
            },
            link: link ?? self.link,
            network: .instagram,
            counts: ChatPost.Counts(replies: commentCount, reposts: nil, likes: likeCount),
        ))
    }
}

public extension InstagramClient {
    /// One post by its shortcode, through the signed-in web session (`/api/v1/media/<id>/info/`); nil when Instagram
    /// has none (deleted, or private to this account).
    func post(shortcode: String) async throws -> InstagramPost? {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }
        guard let mediaId = InstagramPost.mediaId(shortcode: shortcode) else { return nil }
        do {
            let data = try await webJSONRequest(credentials: credentials, method: "GET", path: "/api/v1/media/\(mediaId)/info/")
            return try InstagramPost.parse(data: data, shortcode: shortcode)
        } catch let SourceError.serviceError(message) where message.contains("(HTTP 404)") || message.localizedCaseInsensitiveContains("media not found") {
            return nil
        }
    }
}
