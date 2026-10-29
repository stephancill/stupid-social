import Foundation

/// One Spotify Messages chat: pages its history, polls for new messages while open (Spotify delivers them
/// through a push channel the app can't use), sends text, and marks the chat seen as messages are read.
@MainActor
public final class SpotifyChatViewModel: ChatViewModel {
    private let client: SpotifyClient
    private let chatId: String
    private let viewerUsername: String
    private var loaded: [String: SpotifyChatMessage] = [:]
    private var nextPageToken: String?
    private var profiles: [String: ChatUser] = [:]
    private var pendingProfiles: Set<String> = []
    private var shares: [String: SpotifyShareMetadata] = [:]
    private var tracks: [String: SpotifyTrackMetadata] = [:]
    private var pendingShares: Set<String> = []
    private var previewURLs: [String: URL] = [:]
    private let snapshotCache: ChatSnapshotCache
    /// Whether the first page came from Spotify this visit; until then the messages are the cached snapshot.
    private var hasLoadedHistory = false
    /// The other member of a one-to-one chat, whose name titles it.
    private var partner: String?
    /// The newest incoming message the chat was marked seen at.
    private var seenUpTo: Date?
    private let pageSize = 30
    private let pollInterval: Duration = .seconds(10)

    /// `chatId` is the base62 id from `spotify:chat:<id>`.
    public init(client: SpotifyClient, chatId: String, title: String, viewerUsername: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache()) {
        self.client = client
        self.chatId = chatId
        self.viewerUsername = viewerUsername
        self.snapshotCache = snapshotCache
        super.init(network: .spotify, chatKey: "spotify:\(chatId)", title: title, subtitle: "Spotify", canReply: false)
        restoreSnapshot()
    }

    /// What the chat showed last time, so it opens with its messages, names and track details in place.
    private struct Snapshot: Codable {
        let messages: [SpotifyChatMessage]
        let profiles: [String: ChatUser]
        let tracks: [String: SpotifyTrackMetadata]
        let shares: [String: SpotifyShareMetadata]
        let partner: String?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
    }

    private var snapshotKey: String {
        chatKey
    }

    private func restoreSnapshot() {
        guard let snapshot = snapshotCache.load(Snapshot.self, key: snapshotKey) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        profiles = snapshot.profiles
        tracks = snapshot.tracks
        shares = snapshot.shares
        partner = snapshot.partner
        title = snapshot.title
        subtitle = snapshot.subtitle
        showsSenderNames = snapshot.showsSenderNames
        publish()
    }

    private func saveSnapshot() {
        let newest = loaded.values.sorted { ($0.sentAt ?? .distantPast, $0.id) < ($1.sentAt ?? .distantPast, $1.id) }.suffix(ChatSnapshotCache.messageLimit)
        snapshotCache.save(
            Snapshot(messages: Array(newest), profiles: profiles, tracks: tracks, shares: shares, partner: partner, title: title, subtitle: subtitle, showsSenderNames: showsSenderNames),
            key: snapshotKey,
        )
    }

    override public func connect() async {
        guard !isPolling else { return }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        do {
            let page = try await client.chatHistory(chatId: chatId, pageSize: pageSize, pageToken: nil)
            if let chat = page.chat, chat.isGroup {
                title = chat.name ?? "Group"
                subtitle = "\(chat.members.count) members"
            } else if let chat = page.chat, let other = chat.members.first(where: { $0 != viewerUsername }) {
                partner = other
                showsSenderNames = false
                // Keeps the title it opened with (the profile name from the Chats list) rather than flashing
                // the username, which is often a random ID, until the profile loads.
                if let profile = profiles[other] {
                    title = profile.name
                }
                loadProfile(username: other)
            }
            if !hasLoadedHistory {
                hasLoadedHistory = true
                nextPageToken = page.nextPageToken
                hasEarlierMessages = page.nextPageToken != nil
                // Cached profiles refresh once per visit, quietly, since they render already.
                for username in profiles.keys {
                    loadProfile(username: username)
                }
            }
            merge(page.messages)
            saveSnapshot()
            state = .connected
            startPolling(every: pollInterval)
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        stopPolling()
        saveSnapshot()
    }

    override func poll() async {
        await refreshNewest()
    }

    private func refreshNewest() async {
        guard let page = try? await client.chatHistory(chatId: chatId, pageSize: pageSize, pageToken: nil) else { return }
        merge(page.messages)
    }

    override public func loadEarlier() async {
        guard let token = nextPageToken, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await client.chatHistory(chatId: chatId, pageSize: pageSize, pageToken: token)
            nextPageToken = page.nextPageToken
            hasEarlierMessages = page.nextPageToken != nil
            merge(page.messages)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends optimistically (see `sendOptimistically`); when Spotify doesn't return the message, the refresh
    /// loads it before the sending copy goes.
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state == .connected else { return }
        await sendOptimistically(text: text, attachment: nil, replyToId: nil) {
            guard let sent = try await client.sendChatText(chatId: chatId, text: text) else {
                await refreshNewest()
                return nil
            }
            merge([sent])
            return sent.id
        }
    }

    /// Spotify only marks a whole chat seen, so this sends it once per newer incoming message that is shown.
    override public func markRead(upTo message: ChatMessage) {
        guard let newest = loaded.values.filter({ $0.sender != viewerUsername }).compactMap(\.sentAt).max(),
              let shown = message.timestamp, shown >= newest, seenUpTo.map({ newest > $0 }) ?? true
        else { return }
        seenUpTo = newest
        Task { [client, chatId] in try? await client.markChatSeen(chatId: chatId) }
    }

    // MARK: Display

    private func merge(_ page: [SpotifyChatMessage]) {
        for message in page where !message.id.isEmpty && message.content != .other {
            loaded[message.id] = message
        }
        publish()
    }

    private func publish() {
        let sorted = loaded.values.sorted { ($0.sentAt ?? .distantPast, $0.id) < ($1.sentAt ?? .distantPast, $1.id) }
        var totals: [String: [ChatReaction]] = [:]
        for message in sorted where !message.reactions.isEmpty {
            let counts = Dictionary(grouping: message.reactions, by: \.emoji)
            totals[message.id] = counts
                .map { emoji, reactions in
                    ChatReaction(emoji: emoji, count: reactions.count, includesYou: reactions.contains { $0.username == viewerUsername })
                }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        publish(history: sorted.map(chatMessage), reactions: totals)
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (loaded[messageId]?.reactions ?? [])
            .filter { $0.emoji == emoji }
            .map { ChatReactor(user: user(username: $0.username), date: $0.sentAt, isYou: $0.username == viewerUsername) }
    }

    private func chatMessage(_ message: SpotifyChatMessage) -> ChatMessage {
        let sender = message.sender ?? ""
        let text: String?
        var embeds: [ChatEmbed] = []
        switch message.content {
        case let .text(body):
            text = body
        case let .share(uri):
            text = nil
            embeds = [shareEmbed(uri: uri)]
        case .other:
            text = nil
        }
        return ChatMessage(
            id: message.id,
            sender: user(username: sender),
            timestamp: message.sentAt,
            text: text,
            embeds: embeds,
            isOwn: sender == viewerUsername,
        )
    }

    /// Spotify usernames are often random IDs, so senders show their profile name once it has loaded.
    private func user(username: String) -> ChatUser {
        if let profile = profiles[username] {
            return profile
        }
        loadProfile(username: username)
        return ChatUser(id: username, name: nil, avatarURL: nil)
    }

    private func loadProfile(username: String) {
        guard !username.isEmpty, pendingProfiles.insert(username).inserted else { return }
        Task {
            guard let profile = try? await client.userProfile(username: username) else { return }
            profiles[username] = ChatUser(
                id: username,
                name: profile.display_name,
                avatarURL: profile.images?.first.flatMap { URL(string: $0.url) },
            )
            if username == partner, let name = profiles[username]?.name {
                title = name
            }
            publish()
        }
    }

    /// A shared track as a playable card with its artists, album, year and length; albums, episodes and
    /// playlists as cards with their artwork. Both open in Spotify.
    private func shareEmbed(uri: String) -> ChatEmbed {
        let url = SpotifyMessagesSource.openURL(forShareURI: uri)
        let type = url?.pathComponents.dropFirst().first ?? ""
        let kind = type.isEmpty ? "Spotify" : type.prefix(1).uppercased() + type.dropFirst()
        guard let url, let id = url.pathComponents.last else {
            return .card(title: kind, subtitle: nil, systemImage: "music.note", imageURL: nil, link: nil)
        }
        if type == "track" {
            guard let track = tracks[id] else {
                loadTrack(id: id)
                return .audio(previewId: id, title: "Track", subtitle: nil, detail: nil, imageURL: nil, link: url)
            }
            let length = track.durationMs.map { Duration.milliseconds($0).formatted(.time(pattern: .minuteSecond)) }
            let detail = [track.album, track.releaseYear.map(String.init), length].compactMap(\.self).joined(separator: " · ")
            return .audio(
                previewId: id,
                title: track.name ?? "Track",
                subtitle: track.artists.isEmpty ? nil : track.artists.joined(separator: ", "),
                detail: detail.isEmpty ? nil : detail,
                imageURL: track.coverURL,
                link: url,
            )
        }
        let metadata = shares[url.absoluteString]
        if metadata == nil {
            loadShare(url: url)
        }
        return .card(
            title: metadata?.title ?? "Shared \(kind.lowercased())",
            subtitle: kind,
            systemImage: "music.note",
            imageURL: metadata?.thumbnailURL.flatMap(URL.init(string:)),
            link: url,
        )
    }

    private func loadTrack(id: String) {
        guard pendingShares.insert(id).inserted else { return }
        Task {
            guard let track = try? await client.trackMetadata(trackId: id) else { return }
            tracks[id] = track
            publish()
        }
    }

    private func loadShare(url: URL) {
        guard pendingShares.insert(url.absoluteString).inserted else { return }
        Task {
            guard let metadata = try? await client.shareMetadata(url: url) else { return }
            shares[url.absoluteString] = metadata
            publish()
        }
    }

    /// The track's 30-second preview from its embed page, which `metadata/4` doesn't carry.
    override public func audioPreviewURL(for previewId: String) async -> URL? {
        if let cached = previewURLs[previewId] {
            return cached
        }
        let url = await client.trackPreviewURL(trackId: previewId)
        previewURLs[previewId] = url
        return url
    }
}
