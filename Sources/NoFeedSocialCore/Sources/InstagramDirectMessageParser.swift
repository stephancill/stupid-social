import Foundation

enum InstagramDirectMessageParser {
    static func parse(response: InstagramDirectInboxResponse, accountId: String, includeMediaShares: Bool) -> [NotificationItem] {
        response.inbox.threads.compactMap { thread in
            parse(thread: thread, accountId: accountId, includeMediaShares: includeMediaShares)
        }
    }

    private static func parse(thread: InstagramDirectThread, accountId: String, includeMediaShares: Bool) -> NotificationItem? {
        guard let item = thread.lastPermanentItem else { return nil }
        let viewerId = thread.viewerId ?? accountId
        guard item.userId != viewerId else { return nil }
        guard includeMediaShares || !item.isMediaShare else { return nil }

        let itemTimestamp = item.timestamp ?? thread.lastActivityAt ?? 0
        let seenTimestamp = thread.lastSeenAt?[viewerId]?.timestamp ?? 0
        guard thread.markedAsUnread == true || itemTimestamp > seenTimestamp else { return nil }

        let actors = buildActors(thread: thread, senderId: item.userId, viewerId: viewerId)
        let senderName = actors.first?.username ?? actors.first?.displayName ?? thread.threadTitle ?? "Someone"
        let timestamp = Date(timeIntervalSince1970: TimeInterval(itemTimestamp) / 1_000_000)
        let preview = messagePreview(from: item)
        let text = notificationText(senderName: senderName, item: item)
        let xma = primaryXMA(from: item)
        let imageURL = xma?.previewURL.flatMap(URL.init)
        let targetURL = xma?.targetURL.flatMap(URL.init) ?? URL(string: "https://www.instagram.com/direct/t/\(thread.threadV2Id ?? thread.threadId)/")

        return NotificationItem(
            id: "instagram:direct:\(thread.threadId):\(item.itemId)",
            network: .instagram,
            accountId: accountId,
            sourceId: item.itemId,
            type: .message,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: NotificationTarget(
                id: thread.threadV2Id ?? thread.threadId,
                text: preview,
                url: targetURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                author: actors.first,
                postedAt: timestamp,
            ),
            parentTarget: nil,
        )
    }

    private static func buildActors(thread: InstagramDirectThread, senderId: String?, viewerId: String) -> [NotificationActor] {
        let users = thread.users.filter { $0.pk != viewerId }
        let sortedUsers: [InstagramDirectUser] = if let senderId, let sender = users.first(where: { $0.pk == senderId }) {
            [sender] + users.filter { $0.pk != senderId }
        } else {
            users
        }

        return sortedUsers.prefix(5).map { user in
            NotificationActor(
                id: user.pk,
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicURL.flatMap(URL.init),
            )
        }
    }

    private static func messagePreview(from item: InstagramDirectItem) -> String? {
        if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let auxiliary = item.auxiliaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !auxiliary.isEmpty {
            return auxiliary
        }
        if let xma = primaryXMA(from: item) {
            let values = [xma.titleText, xma.captionBodyText, xma.subtitleText]
            if let value = values.compactMap({ cleaned($0) }).first {
                return value
            }

            if item.itemType == "xma_clip", let username = cleaned(xma.headerTitleText) {
                return "Sent a reel by \(username)"
            }
            if item.itemType == "xma_media_share", let username = cleaned(xma.headerTitleText) {
                return "Sent a post by \(username)"
            }
        }
        switch item.itemType {
        case "xma_reel_mention":
            return "Mentioned you in a story"
        case "xma_reel_share":
            return "Replied to a story"
        case "xma_clip":
            return "Sent a reel"
        case "xma_media_share":
            return "Sent a post"
        case "voice_media":
            return "Sent a voice message"
        case "media", "raven_media":
            return "Sent media"
        case "animated_media":
            return "Sent an animation"
        default:
            return "Sent a message"
        }
    }

    private static func notificationText(senderName: String, item: InstagramDirectItem) -> String {
        switch item.itemType {
        case "xma_reel_share":
            "\(senderName) replied to your story"
        case "xma_reel_mention":
            "\(senderName) mentioned you in their story"
        case "xma_clip":
            "\(senderName) sent you a reel"
        case "xma_media_share":
            "\(senderName) sent you a post"
        default:
            "\(senderName) sent you a message"
        }
    }

    private static func primaryXMA(from item: InstagramDirectItem) -> InstagramDirectXMA? {
        item.xmaReelMention?.first
            ?? item.xmaReelShare?.first
            ?? item.xmaClip?.first
            ?? item.xmaMediaShare?.first
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func buildActorSummary(actors: [NotificationActor]) -> String {
        guard let first = actors.first, let firstName = first.username ?? first.displayName else { return "Someone" }
        let remainingCount = actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }
}
