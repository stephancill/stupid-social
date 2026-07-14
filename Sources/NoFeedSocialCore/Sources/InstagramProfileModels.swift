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
            case id
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

        init(
            pk: UInt64?,
            username: String?,
            fullName: String?,
            profilePicUrl: String?,
            followerCount: Int?,
            followingCount: Int?,
            biography: String?,
            mediaCount: Int?,
            isVerified: Bool?,
            isPrivate: Bool?,
            externalUrl: String?,
            friendshipStatus: InstagramFriendshipStatus?,
        ) {
            self.pk = pk
            self.username = username
            self.fullName = fullName
            self.profilePicUrl = profilePicUrl
            self.followerCount = followerCount
            self.followingCount = followingCount
            self.biography = biography
            self.mediaCount = mediaCount
            self.isVerified = isVerified
            self.isPrivate = isPrivate
            self.externalUrl = externalUrl
            self.friendshipStatus = friendshipStatus
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let pkString = try container.decodeFlexibleStringIfPresent(forKey: .pk) ?? container.decodeFlexibleStringIfPresent(forKey: .id) {
                pk = UInt64(pkString)
            } else {
                pk = nil
            }
            username = try container.decodeIfPresent(String.self, forKey: .username)
            fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
            profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
            followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
            followingCount = try container.decodeIfPresent(Int.self, forKey: .followingCount)
            biography = try container.decodeIfPresent(String.self, forKey: .biography)
            mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
            isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified)
            isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
            externalUrl = try container.decodeIfPresent(String.self, forKey: .externalUrl)
            friendshipStatus = try container.decodeIfPresent(InstagramFriendshipStatus.self, forKey: .friendshipStatus)
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

struct InstagramTopSearchResponse: Decodable {
    struct UserResult: Decodable {
        let user: InstagramUserInfoResponse.InfoUser
    }

    let users: [UserResult]
    let status: String?
}

struct InstagramMediaInfoResponse: Decodable {
    let items: [InstagramMediaInfoItem]
    let status: String?
}

struct InstagramUserFeedResponse: Decodable {
    let items: [InstagramMediaInfoItem]
    let moreAvailable: Bool?
    let nextMaxId: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case items
        case moreAvailable = "more_available"
        case nextMaxId = "next_max_id"
        case status
    }
}

struct InstagramMediaInfoItem: Decodable {
    let id: String?
    let pk: String?
    let code: String?
    let takenAt: Double?
    let likeCount: Int?
    let caption: InstagramMediaCaption?
    let imageVersions2: InstagramImageVersions?
    let videoVersions: [InstagramVideoVersion]?
    let carouselMedia: [InstagramMediaInfoItem]?
    let user: InstagramMediaUser?
    let mediaType: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case pk
        case code
        case takenAt = "taken_at"
        case likeCount = "like_count"
        case caption
        case imageVersions2 = "image_versions2"
        case videoVersions = "video_versions"
        case carouselMedia = "carousel_media"
        case user
        case mediaType = "media_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleStringIfPresent(forKey: .id)
        pk = try container.decodeFlexibleStringIfPresent(forKey: .pk)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        takenAt = try container.decodeIfPresent(Double.self, forKey: .takenAt)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount)
        caption = try? container.decodeIfPresent(InstagramMediaCaption.self, forKey: .caption)
        imageVersions2 = try? container.decodeIfPresent(InstagramImageVersions.self, forKey: .imageVersions2)
        videoVersions = try? container.decodeIfPresent([InstagramVideoVersion].self, forKey: .videoVersions)
        carouselMedia = try? container.decodeIfPresent([InstagramMediaInfoItem].self, forKey: .carouselMedia)
        user = try? container.decodeIfPresent(InstagramMediaUser.self, forKey: .user)
        mediaType = try container.decodeIfPresent(Int.self, forKey: .mediaType)
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

    var thumbnailImageURLs: [URL] {
        let ownURLString = imageVersions2?.candidates?
            .sorted { ($0.width ?? 0) < ($1.width ?? 0) }
            .first?
            .url
        let ownURL = ownURLString.flatMap { URL(string: $0) }
        let own = ownURL.map { [$0] } ?? []
        let carousel = carouselMedia?.flatMap(\.thumbnailImageURLs) ?? []
        return carousel.isEmpty ? own : carousel
    }

    var bestVideoURL: URL? {
        let urlString = videoVersions?
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first?
            .url
        return urlString.flatMap { URL(string: $0) }
    }

    var profilePostMedia: [NetworkProfilePostMedia] {
        let sourceItems = carouselMedia?.isEmpty == false ? carouselMedia ?? [] : [self]
        return sourceItems.compactMap { item in
            guard let imageURL = item.bestImageURLs.first else { return nil }
            return NetworkProfilePostMedia(
                id: item.id ?? item.pk ?? imageURL.absoluteString,
                imageURL: imageURL,
                thumbnailURL: item.thumbnailImageURLs.first ?? imageURL,
                videoURL: item.bestVideoURL,
                isVideo: item.mediaType == 2,
            )
        }
    }

    var profilePost: NetworkProfilePost? {
        guard let imageURL = bestImageURLs.first else { return nil }
        let thumbnailURL = thumbnailImageURLs.first ?? imageURL
        let media = profilePostMedia
        let postURL = code.flatMap { URL(string: "https://www.instagram.com/p/\($0)/") }
        return NetworkProfilePost(
            id: id ?? pk ?? code ?? imageURL.absoluteString,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            media: media,
            url: postURL,
            caption: caption?.text,
            isVideo: media.first?.isVideo ?? (mediaType == 2),
            isCarousel: mediaType == 8 || media.count > 1,
        )
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pkString = try container.decodeFlexibleStringIfPresent(forKey: .pk) {
            pk = UInt64(pkString)
        } else {
            pk = nil
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
    }
}
