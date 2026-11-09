import Foundation

/// The LinkedIn Notifications tab as feed items. LinkedIn writes each card's sentence itself ("Congratulate … on a
/// new position"), so the item keeps it as its text; tapping opens the card's page on linkedin.com. Reading the
/// cards doesn't mark them seen, and the app doesn't either.
public struct LinkedInNotificationSource: NotificationFetching {
    public let network: SocialNetwork = .linkedin

    private let client: LinkedInClient
    private let metadataStore: AccountMetadataStore

    public init(client: LinkedInClient, metadataStore: AccountMetadataStore) {
        self.client = client
        self.metadataStore = metadataStore
    }

    public func fetchNotifications(reason _: RefreshReason) async throws -> [NotificationItem] {
        do {
            return try await client.notificationCards().map { Self.item(from: $0, accountId: metadataStore.accountId) }
        } catch SourceError.notConfigured {
            metadataStore.status = .invalidCredentials
            throw SourceError.notConfigured
        }
    }

    static func item(from card: LinkedInNotificationCard, accountId: String) -> NotificationItem {
        let actor = NotificationActor(
            id: card.actorURL?.absoluteString ?? card.entityUrn,
            network: .linkedin,
            username: card.actorURL.flatMap(vanityName(from:)),
            displayName: card.actorName,
            avatarURL: card.imageURL,
            timestamp: card.publishedAt,
        )
        return NotificationItem(
            id: "linkedin:\(card.entityUrn):\(Int64(card.publishedAt.timeIntervalSince1970))",
            network: .linkedin,
            accountId: accountId,
            sourceId: card.entityUrn,
            type: type(of: card.kind),
            timestamp: card.publishedAt,
            text: headline(card.headline),
            actors: [actor],
            target: NotificationTarget(id: card.entityUrn, text: card.content, url: card.url, author: actor, postedAt: card.publishedAt),
        )
    }

    /// "… View more network updates." is a link on LinkedIn's page, not part of the news.
    static func headline(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: " View more network updates.", with: "")
        return trimmed.isEmpty ? text : trimmed
    }

    /// The card kind from its urn, such as `JOB_CHANGE_PROP`, `MENTION_IN_COMMENT` or `REACTION_TO_POST`.
    static func type(of kind: String) -> NotificationType {
        let kind = kind.uppercased()
        if kind.contains("MENTION") { return .mention }
        if kind.contains("COMMENT") || kind.contains("REPLY") { return .reply }
        if kind.contains("REACT") || kind.contains("LIKE") || kind.contains("SHARE") || kind.contains("REPOST") { return .reaction }
        if kind.contains("FOLLOW") || kind.contains("INVITATION") || kind.contains("CONNECTION") { return .follow }
        if kind.contains("MESSAGE") { return .message }
        if kind.contains("POST") || kind.contains("ARTICLE") { return .post }
        return .unknown
    }

    /// `https://www.linkedin.com/in/some-one` → `some-one`.
    static func vanityName(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "in"), index + 1 < parts.count else { return nil }
        return parts[index + 1].removingPercentEncoding ?? parts[index + 1]
    }
}
