import Foundation

public enum SocialNetwork: String, Codable, CaseIterable, Identifiable, Sendable {
    case x
    case farcaster
    case debug

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .x: "X"
        case .farcaster: "Farcaster"
        case .debug: "Debug"
        }
    }
}

public enum NotificationType: String, Codable, Sendable {
    case mention
    case reply
    case reaction
    case follow
    case unknown
}

public enum AccountStatus: Equatable, Sendable {
    case notConfigured
    case valid
    case invalidCredentials
    case iCloudUnavailable
    case networkUnavailable
    case serviceError(String)

    public var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .valid: "Valid"
        case .invalidCredentials: "Invalid credentials"
        case .iCloudUnavailable: "iCloud unavailable"
        case .networkUnavailable: "Network unavailable"
        case let .serviceError(message): "Service error: \(message)"
        }
    }
}

public enum RefreshReason: Sendable {
    case manual
    case background
    case open
}

public struct NotificationItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let network: SocialNetwork
    public let accountId: String
    public let sourceId: String?
    public let type: NotificationType
    public let timestamp: Date
    public let text: String
    public let actors: [NotificationActor]
    public let target: NotificationTarget?
    public let parentTarget: NotificationTarget?

    public init(
        id: String,
        network: SocialNetwork,
        accountId: String,
        sourceId: String?,
        type: NotificationType,
        timestamp: Date,
        text: String,
        actors: [NotificationActor],
        target: NotificationTarget?,
        parentTarget: NotificationTarget? = nil
    ) {
        self.id = id
        self.network = network
        self.accountId = accountId
        self.sourceId = sourceId
        self.type = type
        self.timestamp = timestamp
        self.text = text
        self.actors = actors
        self.target = target
        self.parentTarget = parentTarget
    }
}

public struct NotificationActor: Hashable, Codable, Sendable {
    public let id: String
    public let network: SocialNetwork
    public let username: String?
    public let displayName: String?
    public let avatarURL: URL?

    public init(id: String, network: SocialNetwork, username: String?, displayName: String?, avatarURL: URL?) {
        self.id = id
        self.network = network
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public struct NotificationTarget: Hashable, Codable, Sendable {
    public let id: String
    public let text: String?
    public let url: URL?

    public init(id: String, text: String?, url: URL?) {
        self.id = id
        self.text = text
        self.url = url
    }
}

public struct DisplayNotificationItem: Identifiable, Hashable {
    public let item: NotificationItem
    public let isUnread: Bool

    public var id: String { item.id }

    public init(item: NotificationItem, isUnread: Bool) {
        self.item = item
        self.isUnread = isUnread
    }
}

public struct NetworkProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let network: SocialNetwork
    public let username: String?
    public let displayName: String?
    public let avatarURL: URL?
    public let followerCount: Int?
    public let followingCount: Int?

    public init(
        id: String,
        network: SocialNetwork,
        username: String?,
        displayName: String?,
        avatarURL: URL?,
        followerCount: Int?,
        followingCount: Int?
    ) {
        self.id = id
        self.network = network
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.followerCount = followerCount
        self.followingCount = followingCount
    }
}

public struct ReadWatermark: Codable, Equatable, Sendable {
    public let network: SocialNetwork
    public let accountId: String
    public let lastReadAt: Date
    public let updatedAt: Date

    public init(network: SocialNetwork, accountId: String, lastReadAt: Date, updatedAt: Date) {
        self.network = network
        self.accountId = accountId
        self.lastReadAt = lastReadAt
        self.updatedAt = updatedAt
    }
}
