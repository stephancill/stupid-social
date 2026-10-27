import Foundation

/// One Instagram Direct thread: pages its history, polls for new messages while open (the web gets them over
/// MQTT, which the app doesn't use), sends text and replies, and moves the read receipt as messages are read.
@MainActor
public final class InstagramChatViewModel: ChatViewModel {
    private let client: InstagramClient
    private let threadFbid: String
    private var loaded: [String: InstagramDirectMessage] = [:]
    private var nextCursor: String?
    /// Messaging id → person, from the thread's users and the viewer.
    private var people: [String: ChatUser] = [:]
    private var viewerFbid: String?
    /// The legacy thread id the read mutation takes.
    private var legacyThreadId: String?
    /// Where the viewer's read receipt is, locally ahead of Instagram while a mark is pending.
    private var readAt: Date?
    private var readSendTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(20)
    private let snapshotCache: ChatSnapshotCache
    /// Whether the thread came from Instagram this visit; until then the messages are the cached snapshot.
    private var hasLoadedHistory = false

    public init(client: InstagramClient, threadFbid: String, title: String, snapshotCache: ChatSnapshotCache = ChatSnapshotCache()) {
        self.client = client
        self.threadFbid = threadFbid
        self.snapshotCache = snapshotCache
        super.init(network: .instagram, title: title, subtitle: "Instagram", canReply: true)
        restoreSnapshot()
    }

    /// What the chat showed last time, so it opens with its messages and people in place.
    private struct Snapshot: Codable {
        let messages: [InstagramDirectMessage]
        let people: [String: ChatUser]
        let viewerFbid: String?
        let legacyThreadId: String?
        let readAt: Date?
        let title: String
        let subtitle: String
        let showsSenderNames: Bool
    }

    private var snapshotKey: String {
        "instagram:\(threadFbid)"
    }

    private func restoreSnapshot() {
        guard let snapshot = snapshotCache.load(Snapshot.self, key: snapshotKey) else { return }
        for message in snapshot.messages {
            loaded[message.id] = message
        }
        people = snapshot.people
        viewerFbid = snapshot.viewerFbid
        legacyThreadId = snapshot.legacyThreadId
        readAt = snapshot.readAt
        title = snapshot.title
        subtitle = snapshot.subtitle
        showsSenderNames = snapshot.showsSenderNames
        // The divider is in the first render, rather than appearing once history arrives.
        firstUnreadMessageId = loaded.values.sorted { ($0.sentAt ?? .distantPast, $0.id) < ($1.sentAt ?? .distantPast, $1.id) }
            .map(chatMessage).first(where: isUnread)?.id
        publish()
    }

    private func saveSnapshot() {
        let newest = loaded.values.sorted { ($0.sentAt ?? .distantPast, $0.id) < ($1.sentAt ?? .distantPast, $1.id) }.suffix(ChatSnapshotCache.messageLimit)
        snapshotCache.save(
            Snapshot(messages: Array(newest), people: people, viewerFbid: viewerFbid, legacyThreadId: legacyThreadId, readAt: readAt, title: title, subtitle: subtitle, showsSenderNames: showsSenderNames),
            key: snapshotKey,
        )
    }

    override public func connect() async {
        guard pollTask == nil else { return }
        if messages.isEmpty {
            state = .connecting
        }
        errorMessage = nil
        do {
            let thread = try await client.directThread(threadFbid: threadFbid)
            apply(thread: thread)
            if !hasLoadedHistory {
                hasLoadedHistory = true
                nextCursor = thread.slideMessages?.pageInfo?.hasNextPage == true ? thread.slideMessages?.pageInfo?.endCursor : nil
                hasEarlierMessages = nextCursor != nil
            }
            merge(thread.messages)
            if firstUnreadMessageId == nil {
                firstUnreadMessageId = messages.first { isUnread($0) }?.id
            }
            saveSnapshot()
            canReact = true
            state = .connected
            startPolling()
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    override public func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        saveSnapshot()
    }

    private func apply(thread: InstagramDirectThread) {
        viewerFbid = thread.viewerFbid
        legacyThreadId = thread.threadId
        if let viewerReadAt = thread.viewerReadAt, viewerReadAt > (readAt ?? .distantPast) {
            readAt = viewerReadAt
        }
        for user in thread.users ?? [] {
            guard let fbid = user.interopMessagingUserFbid else { continue }
            people[fbid] = ChatUser(id: user.id, name: user.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? user.username, avatarURL: user.profilePicUrl.flatMap(URL.init))
        }
        if let viewer = thread.viewer, let fbid = viewer.interopMessagingUserFbid {
            people[fbid] = ChatUser(id: viewer.id ?? fbid, name: "You", avatarURL: viewer.profilePicUrl.flatMap(URL.init))
        }
        showsSenderNames = thread.isGroup == true
        if let threadTitle = thread.threadTitle, !threadTitle.isEmpty {
            title = threadTitle
        }
        subtitle = thread.isGroup == true ? "\(thread.others.count + 1) members" : "Instagram"
    }

    private func startPolling() {
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                await refreshNewest()
            }
        }
    }

    private func refreshNewest() async {
        guard let thread = try? await client.directThread(threadFbid: threadFbid) else { return }
        apply(thread: thread)
        merge(thread.messages)
    }

    override public func loadEarlier() async {
        guard let cursor = nextCursor, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await client.directOlderMessages(threadFbid: threadFbid, cursor: cursor)
            nextCursor = page.pageInfo?.hasNextPage == true ? page.pageInfo?.endCursor : nil
            hasEarlierMessages = nextCursor != nil
            merge(page.edges.map(\.node))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends optimistically (see `sendOptimistically`).
    override public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state == .connected else { return }
        let replyTo = replyingTo?.id
        await sendOptimistically(text: text, attachment: nil, replyToId: replyTo) {
            let sent = try await client.sendDirectText(threadFbid: threadFbid, text: text, replyToMessageId: replyTo)
            // Added as sent; the next poll replaces it with Instagram's copy, which has the same id.
            loaded[sent.id] = InstagramDirectMessage(
                id: sent.id,
                senderFbid: viewerFbid,
                timestampMs: sent.timestampMs,
                contentType: "TEXT",
                textBody: text,
                igdSnippet: nil,
                content: nil,
                repliedToMessageId: replyTo,
                reactions: nil,
                sender: nil,
            )
            publish()
            return sent.id
        }
    }

    /// Instagram keeps one read receipt per person, so this moves it to the newest message shown, shortly after,
    /// whenever that passes an unread message from someone else.
    override public func markRead(upTo message: ChatMessage) {
        guard let shown = message.timestamp, shown > (readAt ?? .distantPast),
              loaded.values.contains(where: { $0.senderFbid != viewerFbid && ($0.sentAt ?? .distantPast) > (readAt ?? .distantPast) && ($0.sentAt ?? .distantFuture) <= shown }),
              let legacyThreadId
        else { return }
        readAt = shown
        updateUnreadCount()
        readSendTask?.cancel()
        readSendTask = Task { [weak self, client, threadFbid, messageId = message.id] in
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil, !Task.isCancelled else { return }
            try? await client.markDirectRead(threadFbid: threadFbid, threadId: legacyThreadId, messageId: messageId)
        }
    }

    // MARK: Display

    private func merge(_ page: [InstagramDirectMessage]) {
        for message in page {
            loaded[message.id] = message
        }
        publish()
    }

    private func publish() {
        let sorted = loaded.values.sorted { ($0.sentAt ?? .distantPast, $0.id) < ($1.sentAt ?? .distantPast, $1.id) }
        var totals: [String: [ChatReaction]] = [:]
        for message in sorted {
            guard let reactions = message.reactions, !reactions.isEmpty else { continue }
            // Grouped by `displayEmoji`, so the stored ❤ and a just-sent ❤️ count together.
            totals[message.id] = Dictionary(grouping: reactions, by: { Self.displayEmoji($0.reaction) })
                .map { emoji, reactions in
                    ChatReaction(emoji: emoji, count: reactions.count, includesYou: reactions.contains { $0.senderFbid == viewerFbid })
                }
                .sorted { ($0.count, $0.emoji) > ($1.count, $1.emoji) }
        }
        publish(history: sorted.map(chatMessage), reactions: totals)
        updateUnreadCount()
    }

    private func isUnread(_ message: ChatMessage) -> Bool {
        message.isUserMessage && !message.isOwn && (message.timestamp ?? .distantPast) > (readAt ?? .distantPast)
    }

    private func updateUnreadCount() {
        // `history`, since `messages` may be held back while the chat opens.
        let count = history.count(where: isUnread)
        if unreadCount != count {
            unreadCount = count
        }
    }

    /// Instagram stores emoji without the variation selector (❤️ comes back as ❤), so one that matches a quick
    /// reaction without it shows as that quick reaction.
    static func displayEmoji(_ emoji: String) -> String {
        let bare = emoji.replacingOccurrences(of: "\u{FE0F}", with: "")
        return quickReactions.first { $0.replacingOccurrences(of: "\u{FE0F}", with: "") == bare } ?? emoji
    }

    override public func yourEmojis(on messageId: String) -> [String] {
        (loaded[messageId]?.reactions ?? []).filter { $0.senderFbid == viewerFbid }.map { Self.displayEmoji($0.reaction) }
    }

    /// Instagram keeps one reaction per person, so a new emoji replaces yours and your current one removes it.
    /// Shown right away, then replaced by Instagram's answer, or put back if it fails.
    override public func toggleReaction(_ emoji: String, on messageId: String) async {
        guard canReact, let viewerFbid, let message = loaded[messageId] else { return }
        let previous = message.reactions
        let mine = previous?.first { $0.senderFbid == viewerFbid }
        let remove = mine.map { Self.displayEmoji($0.reaction) == emoji } ?? false
        let others = (previous ?? []).filter { $0.senderFbid != viewerFbid }
        setReactions(others + (remove ? [] : [.init(reaction: emoji, senderFbid: viewerFbid)]), on: messageId)
        do {
            let reactions = try await client.setDirectReaction(
                threadFbid: threadFbid,
                messageId: messageId,
                emoji: remove ? mine?.reaction ?? emoji : emoji,
                remove: remove,
            )
            setReactions(reactions, on: messageId)
        } catch {
            setReactions(previous, on: messageId)
            errorMessage = error.localizedDescription
        }
    }

    private func setReactions(_ reactions: [InstagramDirectMessage.Reaction]?, on messageId: String) {
        loaded[messageId]?.reactions = reactions
        publish()
    }

    override public func reactors(of emoji: String, on messageId: String) -> [ChatReactor] {
        (loaded[messageId]?.reactions ?? [])
            .filter { Self.displayEmoji($0.reaction) == emoji }
            .map { ChatReactor(user: person(fbid: $0.senderFbid, sender: nil), date: nil, isYou: $0.senderFbid == viewerFbid) }
    }

    private func person(fbid: String?, sender: InstagramDirectMessage.Sender?) -> ChatUser {
        if let fbid, let person = people[fbid] {
            return person
        }
        return ChatUser(
            id: fbid ?? "",
            name: sender?.name ?? sender?.userDict?.username,
            avatarURL: sender?.userDict?.profilePicUrl.flatMap(URL.init),
        )
    }

    private func chatMessage(_ message: InstagramDirectMessage) -> ChatMessage {
        let content = message.content
        let isOwn = message.senderFbid != nil && message.senderFbid == viewerFbid
        if content?.typename == "SlideMessageAdminText" {
            let text = content?.textFragments?.compactMap(\.plaintext).joined() ?? InstagramDirectMessageParser.preview(of: message)
            return ChatMessage(
                id: message.id,
                sender: ChatUser(id: "instagram", name: "Instagram", avatarURL: nil, isSystem: true),
                timestamp: message.sentAt,
                text: text.trimmingCharacters(in: .whitespaces),
                isOwn: false,
            )
        }

        var text = [message.textBody, content?.textBody, content?.xmaTextBody]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var embeds: [ChatEmbed] = []
        for media in content?.media ?? [] {
            guard let url = (media.isVideo ? media.previewCdnUrl : media.attachmentCdnUrl ?? media.previewCdnUrl).flatMap(URL.init) else { continue }
            let aspectRatio = media.previewWidth.flatMap { width in media.previewHeight.map { width / max($0, 1) } }
            if media.isVideo {
                embeds.append(.card(title: "Video", subtitle: "Open in Instagram", systemImage: "video", imageURL: url, link: threadURL))
            } else {
                embeds.append(.image(url: url, aspectRatio: aspectRatio, alt: nil, link: nil, opensViewer: true))
            }
        }
        if let xma = content?.xma {
            embeds.append(shareEmbed(xma, message: message))
        }
        if text == nil, embeds.isEmpty {
            text = InstagramDirectMessageParser.preview(of: message)
        }
        return ChatMessage(
            id: message.id,
            sender: person(fbid: message.senderFbid, sender: message.sender),
            timestamp: message.sentAt,
            text: text,
            embeds: embeds,
            replyToId: message.repliedToMessageId,
            isOwn: isOwn,
        )
    }

    /// A shared post, reel or story as a card that opens it; an expired one as a card with its caption.
    private func shareEmbed(_ xma: InstagramDirectContent.XMA, message: InstagramDirectMessage) -> ChatEmbed {
        let kind = InstagramDirectMessageParser.shareKind(of: message)
        let title = [xma.titleText, xma.eyebrowText, xma.captionBodyText].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let author = xma.headerTitleText.flatMap { $0.isEmpty ? nil : $0 }
        let fallbackTitle = switch kind {
        case .reel: "Reel"
        case .post: "Post"
        case .storyReply: "Story"
        case nil: "Attachment"
        }
        return .card(
            title: title ?? author.map { "\(fallbackTitle) by \($0)" } ?? fallbackTitle,
            subtitle: title == nil ? nil : author,
            systemImage: kind == .reel ? "play.rectangle" : "photo",
            imageURL: xma.previewImage?.url.flatMap(URL.init),
            link: xma.targetUrl.flatMap(URL.init),
        )
    }

    private var threadURL: URL? {
        URL(string: "https://www.instagram.com/direct/t/\(threadFbid)/")
    }
}
