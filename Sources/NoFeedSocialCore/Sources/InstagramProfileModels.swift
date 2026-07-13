import Foundation

public struct InstagramVerifiedUser {
    public let pk: UInt64
    public let username: String
    public let fullName: String
    public let profilePicURL: URL?
}

public struct InstagramCurrentUserProfile {
    public let pk: UInt64
    public let username: String
    public let fullName: String?
    public let profilePicURL: URL?
    public let followerCount: Int?
    public let followingCount: Int?
    public let postsCount: Int?
    public let bio: String?
    public let websiteURL: URL?
    public let isVerified: Bool?
    public let isPrivate: Bool?
}

struct InstagramWebStoriesTrayResponse: Decodable {
    struct Payload: Decodable {
        let reelsTray: InstagramReelsTrayResponse?
        let xdtViewer: InstagramWebViewer?

        enum CodingKeys: String, CodingKey {
            case reelsTray = "xdt_api__v1__feed__reels_tray"
            case xdtViewer = "xdt_viewer"
        }
    }

    let data: Payload
    let status: String?
}

struct InstagramWebViewer: Decodable {
    struct User: Decodable {
        let id: String
        let username: String
        let profilePicUrl: String?

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case profilePicUrl = "profile_pic_url"
        }
    }

    let user: User
}

struct InstagramWebProfileInfoResponse: Decodable {
    struct Payload: Decodable {
        let user: User
    }

    struct User: Decodable {
        let id: String?
        let username: String?
        let fullName: String?
        let profilePicUrl: String?
        let edgeFollowedBy: CountEdge?
        let edgeFollow: CountEdge?
        let biography: String?
        let edgeOwnerToTimelineMedia: CountEdge?
        let isVerified: Bool?
        let isPrivate: Bool?
        let externalUrl: String?

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
            case edgeFollowedBy = "edge_followed_by"
            case edgeFollow = "edge_follow"
            case biography
            case edgeOwnerToTimelineMedia = "edge_owner_to_timeline_media"
            case isVerified = "is_verified"
            case isPrivate = "is_private"
            case externalUrl = "external_url"
        }

        var asInfoUser: InstagramUserInfoResponse.InfoUser {
            InstagramUserInfoResponse.InfoUser(
                pk: id.flatMap(UInt64.init),
                username: username,
                fullName: fullName,
                profilePicUrl: profilePicUrl,
                followerCount: edgeFollowedBy?.count,
                followingCount: edgeFollow?.count,
                biography: biography,
                mediaCount: edgeOwnerToTimelineMedia?.count,
                isVerified: isVerified,
                isPrivate: isPrivate,
                externalUrl: externalUrl,
                friendshipStatus: nil,
            )
        }
    }

    struct CountEdge: Decodable {
        let count: Int?
    }

    let data: Payload
    let status: String?
}

struct InstagramCurrentUserResponse: Decodable {
    struct User: Decodable {
        let pk: UInt64
        let username: String
        let fullName: String
        let profilePicUrl: String?

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
        }
    }

    let user: User
    let status: String
}

public struct InstagramUserInfoResponse: Decodable {
    public struct InfoUser: Decodable {
        public let pk: UInt64?
        public let username: String?
        public let fullName: String?
        public let profilePicUrl: String?
        public let followerCount: Int?
        public let followingCount: Int?
        public let biography: String?
        public let mediaCount: Int?
        public let isVerified: Bool?
        public let isPrivate: Bool?
        public let externalUrl: String?
        public let friendshipStatus: InstagramFriendshipStatus?

        enum CodingKeys: String, CodingKey {
            case pk
            case username
            case fullName = "full_name"
            case profilePicUrl = "profile_pic_url"
            case followerCount = "follower_count"
            case followingCount = "following_count"
            case biography
            case mediaCount = "media_count"
            case isVerified = "is_verified"
            case isPrivate = "is_private"
            case externalUrl = "external_url"
            case friendshipStatus = "friendship_status"
        }
    }

    public struct InstagramFriendshipStatus: Decodable {
        public let following: Bool?
        public let followedBy: Bool?
        public let isBestie: Bool?
    }

    public let user: InfoUser
    public let status: String?
}

struct InstagramMediaInfoResponse: Decodable {
    let items: [InstagramMediaInfoItem]
    let status: String?
}

struct InstagramMediaInfoItem: Decodable {
    let id: String
    let takenAt: Double?
    let likeCount: Int?
    let caption: InstagramMediaCaption?
    let imageVersions2: InstagramImageVersions?
    let carouselMedia: [InstagramMediaInfoItem]?
    let user: InstagramMediaUser?

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case likeCount = "like_count"
        case caption
        case imageVersions2 = "image_versions2"
        case carouselMedia = "carousel_media"
        case user
    }

    var bestImageURLs: [URL] {
        let ownURLString = imageVersions2?.candidates?
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first?
            .url
        let ownURL = ownURLString.flatMap { URL(string: $0) }
        let own = ownURL.map { [$0] } ?? []
        let carousel = carouselMedia?.flatMap(\.bestImageURLs) ?? []
        return carousel.isEmpty ? own : carousel
    }
}

struct InstagramMediaCaption: Decodable {
    let text: String?
}

struct InstagramMediaUser: Decodable {
    let pk: UInt64?
    let username: String?
    let fullName: String?
    let profilePicUrl: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
    }
}
