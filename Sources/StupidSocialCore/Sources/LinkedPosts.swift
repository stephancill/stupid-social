import Foundation

/// A post a link in a chat points at, drawn in its place in every chat (`ChatKit.resolveLink`).
public enum LinkedPost: Hashable, Sendable, Codable {
    case x(XPost)
    case instagram(InstagramPost)
    case bluesky(BlueskyPost)

    /// The post with its own link, not the one a chat used: a message that links one post several ways (Discord's
    /// preview of an x.com link is a twitter.com link) then has equal embeds, which chats show once.
    public var chatEmbed: ChatEmbed {
        switch self {
        case let .x(post): post.chatEmbed(link: nil)
        case let .instagram(post): post.chatEmbed(link: nil)
        case let .bluesky(post): post.chatEmbed(link: nil)
        }
    }
}

/// How one network's post links resolve: the post's key in a link, nil when the link isn't one or nothing can load it
/// now (such as no signed-in account), and loading it, nil when the network has no such post.
public struct LinkedPostSource {
    public let network: String
    public let key: @MainActor (URL) -> String?
    public let load: @MainActor (String) async throws -> LinkedPost?

    public init(network: String, key: @escaping @MainActor (URL) -> String?, load: @escaping @MainActor (String) async throws -> LinkedPost?) {
        self.network = network
        self.key = key
        self.load = load
    }
}

/// Posts that chats link to, on every network with a source, loaded once and kept in `LinkedPostCache` across
/// launches. Chats show what the network sent until a post arrives; `ChatKit.linksDidResolve()` then draws them again.
@MainActor
public final class LinkedPostResolver {
    private let sources: [LinkedPostSource]
    private let cache: LinkedPostCache
    private var loading: Set<String> = []
    /// Posts the network has none of (deleted or private) aren't asked for again; failed loads are, after a while.
    private var unavailable: Set<String> = []
    private var failedAt: [String: Date] = [:]
    /// Kept posts loaded again this session, for their counts.
    private var refreshed: Set<String> = []
    private static let retryAfter: TimeInterval = 300

    public init(sources: [LinkedPostSource], cache: LinkedPostCache = .shared) {
        self.sources = sources
        self.cache = cache
    }

    /// The embed for a link to a post, for `ChatKit.resolveLink`: the post once kept, else nil while it loads.
    public func embed(for url: URL) -> ChatEmbed? {
        for source in sources {
            guard let key = source.key(url) else { continue }
            let id = "\(source.network):\(key)"
            let post = cache.post(id)
            if post == nil || cache.isStale(id) {
                resolve(id, key: key, source: source)
            }
            return post?.chatEmbed
        }
        return nil
    }

    public func post(_ id: String) -> LinkedPost? {
        cache.post(id)
    }

    /// Loads the post unless it's kept, loading, or unavailable, and has chats draw again once it arrives. A kept
    /// post older than `LinkedPostCache.staleAfter` shows as kept and loads again once a session.
    private func resolve(_ id: String, key: String, source: LinkedPostSource) {
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
                if let post = try await source.load(key) {
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
}

/// Posts chats have shown, kept on disk so a chat draws them in its first frame on later launches instead of
/// growing when they load. Keyed `<network>:<post key>`. Read off the main thread at launch.
@MainActor
public final class LinkedPostCache {
    public static let shared = LinkedPostCache(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LinkedPosts.json"))

    /// After this a kept post still shows, and loads again for its counts (and Instagram's expiring media URLs).
    nonisolated static let staleAfter: TimeInterval = 24 * 60 * 60
    /// Posts not loaded for this long are dropped, and beyond `limit` the least recently loaded.
    nonisolated static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let limit = 1000

    struct Entry: Codable {
        let post: LinkedPost
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

    func post(_ id: String) -> LinkedPost? {
        entries[id]?.post
    }

    func isStale(_ id: String) -> Bool {
        entries[id].map { Date().timeIntervalSince($0.loadedAt) > Self.staleAfter } ?? false
    }

    func insert(_ post: LinkedPost, id: String, at date: Date = Date()) {
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
