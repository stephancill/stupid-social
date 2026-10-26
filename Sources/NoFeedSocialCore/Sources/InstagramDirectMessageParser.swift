import Foundation

enum InstagramDirectMessageParser {
    /// One item per thread whose newest message is unread and from someone else.
    static func parse(threads: [InstagramDirectThread], accountId: String, includeMediaShares: Bool) -> [NotificationItem] {
        threads.compactMap { thread in
            parse(thread: thread, accountId: accountId, includeMediaShares: includeMediaShares)
        }
    }

    private static func parse(thread: InstagramDirectThread, accountId: String, includeMediaShares: Bool) -> NotificationItem? {
        guard let message = thread.messages.first, message.senderFbid != thread.viewerFbid else { return nil }
        guard includeMediaShares || !message.isMediaShare else { return nil }
        guard thread.markedAsUnread == true || thread.unreadMessages.contains(where: { $0.id == message.id }) else { return nil }

        let actors = buildActors(thread: thread, senderFbid: message.senderFbid)
        let senderName = actors.first?.username ?? actors.first?.displayName ?? thread.threadTitle ?? "Someone"
        let timestamp = message.sentAt ?? Date()
        let xma = message.content?.xma
        let imageURL = (xma?.previewImage?.url ?? message.content?.media.first?.previewCdnUrl).flatMap(URL.init)
        let targetURL = xma?.targetUrl.flatMap(URL.init) ?? URL(string: "https://www.instagram.com/direct/t/\(thread.threadFbid)/")

        return NotificationItem(
            id: "instagram:direct:\(thread.threadFbid):\(message.id)",
            network: .instagram,
            accountId: accountId,
            sourceId: message.id,
            type: .message,
            timestamp: timestamp,
            text: notificationText(senderName: senderName, message: message),
            actors: actors,
            target: NotificationTarget(
                id: thread.threadFbid,
                text: preview(of: message),
                url: targetURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                author: actors.first,
                postedAt: timestamp,
            ),
            parentTarget: nil,
        )
    }

    /// The thread's other people, the sender first.
    private static func buildActors(thread: InstagramDirectThread, senderFbid: String?) -> [NotificationActor] {
        let others = thread.others
        let sorted = others.filter { $0.interopMessagingUserFbid == senderFbid } + others.filter { $0.interopMessagingUserFbid != senderFbid }
        return sorted.prefix(5).map { user in
            NotificationActor(
                id: user.id,
                network: .instagram,
                username: user.username,
                displayName: user.fullName,
                avatarURL: user.profilePicUrl.flatMap(URL.init),
            )
        }
    }

    /// The text, or a description of what was sent.
    static func preview(of message: InstagramDirectMessage) -> String {
        let content = message.content
        let candidates = [
            message.textBody,
            content?.textBody,
            content?.xmaTextBody,
            content?.textFragments?.compactMap(\.plaintext).joined(),
            content?.xma?.titleText,
            content?.xma?.captionBodyText,
        ]
        if let text = candidates.compactMap(cleaned).first {
            return text
        }
        switch shareKind(of: message) {
        case .reel: return "Sent a reel"
        case .post: return "Sent a post"
        case .storyReply: return "Replied to a story"
        case nil: break
        }
        if let media = content?.media, !media.isEmpty {
            return media.allSatisfy(\.isVideo) ? "Sent a video" : "Sent a photo"
        }
        return cleaned(message.igdSnippet) ?? "Sent a message"
    }

    private static func notificationText(senderName: String, message: InstagramDirectMessage) -> String {
        switch shareKind(of: message) {
        case .reel: "\(senderName) sent you a reel"
        case .post: "\(senderName) sent you a post"
        case .storyReply: "\(senderName) replied to your story"
        case nil: "\(senderName) sent you a message"
        }
    }

    enum ShareKind {
        case reel
        case post
        case storyReply
    }

    static func shareKind(of message: InstagramDirectMessage) -> ShareKind? {
        guard let xma = message.content?.xma else { return nil }
        if message.contentType == "MONTAGE_SHARE_XMA" || xma.targetUrl?.contains("/stories/") == true {
            return .storyReply
        }
        guard message.isMediaShare else { return nil }
        return xma.previewImage?.previewImageDecorationType == "REEL" || xma.targetUrl?.contains("/reel/") == true ? .reel : .post
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
