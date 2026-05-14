import Foundation

@MainActor
public protocol NotificationSource {
    var network: SocialNetwork { get }

    func validateAccount() async throws -> AccountStatus
    func fetchUnreadCount() async throws -> Int?
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
    func fetchProfile(id: String) async throws -> NetworkProfile
    func fetchTargetMetrics(for item: NotificationItem) async throws -> NotificationTargetMetrics
}

public extension NotificationSource {
    func fetchTargetMetrics(for _: NotificationItem) async throws -> NotificationTargetMetrics {
        throw SourceError.unsupported
    }
}

public struct NotificationTargetMetrics: Hashable, Sendable {
    public let author: NotificationActor?
    public let text: String?
    public let imageURLs: [URL]
    public let postedAt: Date?
    public let likeCount: Int?
    public let relatedTargets: [NotificationTarget]

    public init(
        author: NotificationActor? = nil,
        text: String? = nil,
        imageURLs: [URL] = [],
        postedAt: Date? = nil,
        likeCount: Int? = nil,
        relatedTargets: [NotificationTarget] = []
    ) {
        self.author = author
        self.text = text
        self.imageURLs = imageURLs
        self.postedAt = postedAt
        self.likeCount = likeCount
        self.relatedTargets = relatedTargets
    }
}

public enum SourceError: LocalizedError {
    case notConfigured
    case unsupported
    case endpointSpikeRequired
    case invalidResponse
    case serviceError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Account is not configured."
        case .unsupported: "This source capability is not supported."
        case .endpointSpikeRequired: "X endpoint discovery must be completed before this is implemented."
        case .invalidResponse: "The service returned an invalid response."
        case let .serviceError(message): message
        }
    }
}
