import Foundation

@MainActor
public protocol SocialSource {
    var network: SocialNetwork { get }
}

public protocol AccountValidating: SocialSource {
    func validateAccount() async throws -> AccountStatus
}

public protocol NotificationFetching: SocialSource {
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
}

public protocol ProfileFetching: SocialSource {
    func fetchProfile(id: String) async throws -> NetworkProfile
    func fetchProfilePosts(id: String, cursor: String?, count: Int) async throws -> NetworkProfilePostsPage
    func searchProfiles(query: String) async throws -> [NetworkProfile]
}

public extension ProfileFetching {
    func fetchProfilePosts(id _: String, cursor _: String?, count _: Int) async throws -> NetworkProfilePostsPage {
        throw SourceError.unsupported
    }

    func searchProfiles(query _: String) async throws -> [NetworkProfile] {
        []
    }
}

public protocol NotificationTargetDetailFetching: SocialSource {
    func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails
}

public protocol StoryFetching: SocialSource {
    var hasMoreStoryReels: Bool { get }
    func fetchStoryReels() async throws -> [InstagramStoryReel]
    func fetchNextStoryReelPage() async throws -> [InstagramStoryReel]
}

public protocol StoryPosting: SocialSource {
    func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws
    func deleteStory(mediaId: String, isVideo: Bool) async throws
    func setStoryLiked(mediaId: String, liked: Bool) async throws
}

public protocol ActivityFetching: SocialSource {
    func fetchActivity(reason: RefreshReason) async throws -> [SpotifyActivityItem]
}

public struct NotificationTargetDetails: Hashable, Sendable {
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
        relatedTargets: [NotificationTarget] = [],
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
