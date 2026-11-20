import Foundation

/// A post as chats show it: its author, text, media and the post it quotes
/// (`scripts/x-web-client.py post-preview`).
public struct XPost: Hashable, Sendable, Codable {
    public struct Media: Hashable, Sendable, Codable {
        public enum Kind: Sendable, Codable {
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

    public let replyCount: Int?
    public let repostCount: Int?
    public let likeCount: Int?

    public init(id: String, authorName: String, screenName: String, avatarURL: URL? = nil, isVerified: Bool = false, postedAt: Date? = nil, text: String, media: [Media] = [], replyCount: Int? = nil, repostCount: Int? = nil, likeCount: Int? = nil, quoted: XPost? = nil) {
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.likeCount = likeCount
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
            counts: ChatPost.Counts(replies: replyCount, reposts: repostCount, likes: likeCount),
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
            media: (legacy.extendedEntities?.media ?? []).compactMap { media(from: $0) },
            replyCount: legacy.replyCount,
            // X's repost count leaves out quotes, which it counts apart.
            repostCount: legacy.retweetCount,
            likeCount: legacy.favoriteCount,
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

    static func media(from item: XThreadResponse.Media, maxBitrate: Int = XPostParser.maxBitrate) -> XPost.Media? {
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

/// Posts that chats link to, loaded once per account and kept in `XPostCache` across launches. Chats show what the
/// network sent until a post arrives; `ChatKit.linksDidResolve()` then draws them again.
@MainActor
public final class XPostResolver {
    private let load: @Sendable (String) async throws -> XPost?
    private let cache: XPostCache
    private var loading: Set<String> = []
    /// Posts X has none of (deleted or protected) aren't asked for again; failed loads are, after a while.
    private var unavailable: Set<String> = []
    private var failedAt: [String: Date] = [:]
    /// Kept posts loaded again this session, for their counts.
    private var refreshed: Set<String> = []
    private static let retryAfter: TimeInterval = 300

    public init(cache: XPostCache = .shared, load: @escaping @Sendable (String) async throws -> XPost?) {
        self.cache = cache
        self.load = load
    }

    public convenience init(client: XClient) {
        self.init { try await client.post(id: $0) }
    }

    public func post(_ id: String) -> XPost? {
        cache.post(id)
    }

    /// Loads the post unless it's kept, loading, or unavailable, and has chats draw again once it arrives. A kept
    /// post older than `XPostCache.staleAfter` shows as kept and loads again once a session.
    public func resolve(_ id: String) {
        let isStale = cache.isStale(id)
        guard cache.post(id) == nil || (isStale && !refreshed.contains(id)), !unavailable.contains(id), !loading.contains(id),
              failedAt[id].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true
        else { return }
        loading.insert(id)
        Task {
            defer { loading.remove(id) }
            // Kept posts read from disk at launch draw without loading; reading them drew chats again.
            await cache.ready()
            if cache.post(id) != nil, !cache.isStale(id) {
                return
            }
            if cache.post(id) != nil {
                refreshed.insert(id)
            }
            do {
                if let post = try await load(id) {
                    let changed = cache.post(id) != post
                    cache.insert(post, id: id)
                    if changed {
                        ChatKit.linksDidResolve()
                    }
                } else {
                    unavailable.insert(id)
                    cache.remove(id)
                }
                failedAt[id] = nil
            } catch {
                failedAt[id] = Date()
            }
        }
    }

    /// The embed for a link to a post, for `ChatKit.resolveLink`: the post once kept, else nil while it loads.
    public func embed(for url: URL) -> ChatEmbed? {
        guard let id = XPost.id(in: url) else { return nil }
        let post = cache.post(id)
        if post == nil || cache.isStale(id) {
            resolve(id)
        }
        return post?.chatEmbed(link: url)
    }
}

/// Posts chats have shown, kept on disk so a chat draws them in its first frame on later launches instead of
/// growing when they load. Shared by every X account's resolver. Read off the main thread at launch.
@MainActor
public final class XPostCache {
    public static let shared = XPostCache(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XPosts.json"))

    /// After this a kept post still shows, and loads again for its counts.
    nonisolated static let staleAfter: TimeInterval = 24 * 60 * 60
    /// Posts not loaded for this long are dropped, and beyond `limit` the least recently loaded.
    nonisolated static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let limit = 1000

    struct Entry: Codable {
        let post: XPost
        let loadedAt: Date
    }

    private let url: URL
    private var entries: [String: Entry] = [:]
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    public init(url: URL) {
        self.url = url
        loadTask = Task { [weak self, url] in
            let kept = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            guard let self else { return }
            // Posts loaded while reading are newer.
            entries.merge(kept) { current, _ in current }
            if !kept.isEmpty {
                ChatKit.linksDidResolve()
            }
        }
    }

    func ready() async {
        await loadTask?.value
    }

    func post(_ id: String) -> XPost? {
        entries[id]?.post
    }

    func isStale(_ id: String) -> Bool {
        entries[id].map { Date().timeIntervalSince($0.loadedAt) > Self.staleAfter } ?? false
    }

    func insert(_ post: XPost, id: String, at date: Date = Date()) {
        entries[id] = Entry(post: post, loadedAt: date)
        scheduleSave()
    }

    func remove(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    /// Saves a second after the last change, so a chat full of posts writes once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            await ready()
            let kept = Self.pruned(entries, now: Date())
            entries = kept
            let url = url
            await Task.detached(priority: .utility) { Self.write(kept, to: url) }.value
        }
    }

    nonisolated static func pruned(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        let fresh = entries.filter { now.timeIntervalSince($0.value.loadedAt) < maxAge }
        guard fresh.count > limit else { return fresh }
        return Dictionary(uniqueKeysWithValues: fresh.sorted { $0.value.loadedAt > $1.value.loadedAt }.prefix(limit).map { ($0.key, $0.value) })
    }

    private nonisolated static func read(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return pruned((try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:], now: Date())
    }

    private nonisolated static func write(_ entries: [String: Entry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
