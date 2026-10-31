import Foundation

@MainActor
public protocol SocialSource: Sendable {
    var network: SocialNetwork { get }
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

/// The viewer's engagement with one post, and the post's public counts.
public struct PostEngagement: Hashable, Sendable {
    public var replyCount: Int
    public var repostCount: Int
    public var quoteCount: Int
    public var likeCount: Int
    public var isLiked: Bool
    public var isReposted: Bool

    public init(replyCount: Int, repostCount: Int, quoteCount: Int, likeCount: Int, isLiked: Bool, isReposted: Bool) {
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.quoteCount = quoteCount
        self.likeCount = likeCount
        self.isLiked = isLiked
        self.isReposted = isReposted
    }
}

/// Liking, reposting, replying to and quoting posts.
public protocol PostEngaging: SocialSource {
    func fetchEngagement(postId: String) async throws -> PostEngagement
    func setLiked(postId: String, liked: Bool) async throws
    func setReposted(postId: String, reposted: Bool) async throws
    /// The network's own page for reposting, when reposting can't be done from here; `setReposted` then only undoes.
    func repostPageURL(postId: String) -> URL?
    func reply(to postId: String, text: String) async throws
    func quote(postId: String, text: String) async throws
}

public extension PostEngaging {
    func repostPageURL(postId _: String) -> URL? {
        nil
    }
}

/// The thread a post belongs to: the posts it replies to, and the post.
public struct PostThread: Sendable {
    public struct Post: Hashable, Sendable {
        public let target: NotificationTarget
        public let engagement: PostEngagement?

        public init(target: NotificationTarget, engagement: PostEngagement?) {
            self.target = target
            self.engagement = engagement
        }
    }

    /// Oldest first, ending with the post the focal post replies to.
    public var ancestors: [Post]
    public var focal: Post?

    public init(ancestors: [Post] = [], focal: Post? = nil) {
        self.ancestors = ancestors
        self.focal = focal
    }
}

/// Loading the thread a post belongs to.
public protocol PostThreadLoading: SocialSource {
    func fetchThread(postId: String) async throws -> PostThread
}

public protocol RelationshipMutating: SocialSource {
    func setFollowing(profile: NetworkProfile, follow: Bool) async throws
    func setPostNotifications(profile: NetworkProfile, enabled: Bool) async throws
}

public extension RelationshipMutating {
    func setFollowing(profile _: NetworkProfile, follow _: Bool) async throws {
        throw SourceError.unsupported
    }

    func setPostNotifications(profile _: NetworkProfile, enabled _: Bool) async throws {
        throw SourceError.unsupported
    }
}

public protocol StoryFetching: SocialSource {
    var hasMoreStoryReels: Bool { get }
    func fetchStoryReels() async throws -> [InstagramStoryReel]
    func fetchNextStoryReelPage() async throws -> [InstagramStoryReel]
}

public protocol StoryPosting: SocialSource {
    func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String, mentions: [InstagramStoryMentionPlacement], closeFriends: Bool) async throws
    func deleteStory(mediaId: String, isVideo: Bool) async throws
    func setStoryLiked(mediaId: String, liked: Bool) async throws
}

public protocol ActivityFetching: SocialSource {
    func fetchActivity(reason: RefreshReason) async throws -> [SpotifyActivityItem]
}

public protocol GitHubActivityFetching: SocialSource {
    func fetchGitHubActivity(reason: RefreshReason) async throws -> [GitHubActivityGroup]
}

public struct NotificationTargetDetails: Hashable, Sendable {
    public let author: NotificationActor?
    public let text: String?
    public let imageURLs: [URL]
    public let postedAt: Date?
    public let likeCount: Int?
    public let engagement: PostEngagement?
    public let relatedTargets: [NotificationTarget]

    public init(
        author: NotificationActor? = nil,
        text: String? = nil,
        imageURLs: [URL] = [],
        postedAt: Date? = nil,
        likeCount: Int? = nil,
        engagement: PostEngagement? = nil,
        relatedTargets: [NotificationTarget] = [],
    ) {
        self.author = author
        self.text = text
        self.imageURLs = imageURLs
        self.postedAt = postedAt
        self.likeCount = likeCount
        self.engagement = engagement
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
