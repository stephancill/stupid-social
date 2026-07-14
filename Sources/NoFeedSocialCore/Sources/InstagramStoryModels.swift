import Foundation

struct InstagramStoryPagePayload: Decodable {
    let xdtAPIReelsMedia: InstagramStoryPageReelsMedia

    enum CodingKeys: String, CodingKey {
        case xdtAPIReelsMedia = "xdt_api__v1__feed__reels_media"
    }
}

struct InstagramStoryPageReelsMedia: Decodable {
    let reelsMedia: [InstagramReel]

    enum CodingKeys: String, CodingKey {
        case reelsMedia = "reels_media"
    }
}

struct InstagramReelsTrayResponse: Decodable {
    let tray: [InstagramTrayItem]
    let status: String?
}

struct InstagramTrayItem: Decodable {
    let id: String
    let latestReelMedia: Double?
    let hasBestiesMedia: Bool
    let expiringAt: Double?
    let mediaCount: Int?
    let seen: Int
    let muted: Bool?
    let user: InstagramTrayUser
    let reelType: String?

    var isMuted: Bool {
        muted == true || user.friendshipStatus?.isMutingReel == true || user.friendshipStatus?.muting == true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case latestReelMedia = "latest_reel_media"
        case hasBestiesMedia = "has_besties_media"
        case expiringAt = "expiring_at"
        case mediaCount = "media_count"
        case seen
        case muted
        case user
        case reelType = "reel_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intId = try? container.decode(UInt64.self, forKey: .id) {
            id = String(intId)
        } else {
            id = try container.decode(String.self, forKey: .id)
        }
        latestReelMedia = try container.decodeIfPresent(Double.self, forKey: .latestReelMedia)
        hasBestiesMedia = try container.decodeIfPresent(Bool.self, forKey: .hasBestiesMedia) ?? false
        expiringAt = try container.decodeIfPresent(Double.self, forKey: .expiringAt)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        seen = try container.decodeIfPresent(Int.self, forKey: .seen) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted)
        user = try container.decode(InstagramTrayUser.self, forKey: .user)
        reelType = try container.decodeIfPresent(String.self, forKey: .reelType)
    }
}

struct InstagramTrayUser: Decodable {
    let pk: UInt64
    let username: String?
    let fullName: String?
    let profilePicUrl: String?
    let isPrivate: Bool?
    let isVerified: Bool?
    let friendshipStatus: InstagramTrayFriendshipStatus?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
        case isPrivate = "is_private"
        case isVerified = "is_verified"
        case friendshipStatus = "friendship_status"
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uint = try? container.decode(UInt64.self, forKey: .pk) {
            pk = uint
        } else if let string = try? container.decode(String.self, forKey: .pk), let uint = UInt64(string) {
            pk = uint
        } else if let string = try? container.decode(String.self, forKey: .id), let uint = UInt64(string) {
            pk = uint
        } else {
            throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Instagram user pk"))
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified)
        friendshipStatus = try container.decodeIfPresent(InstagramTrayFriendshipStatus.self, forKey: .friendshipStatus)
    }
}

struct InstagramTrayFriendshipStatus: Decodable {
    let muting: Bool?
    let isMutingReel: Bool?

    enum CodingKeys: String, CodingKey {
        case muting
        case isMutingReel = "is_muting_reel"
    }
}

struct InstagramUserStoryResponse: Decodable {
    let reel: InstagramReel?
    let status: String?
}

struct InstagramReelsMediaResponse: Decodable {
    let reels: [String: InstagramReel]
    let status: String?
}

struct InstagramReel: Decodable {
    let id: UInt64
    let latestReelMedia: Double?
    let expiringAt: Double?
    let mediaCount: Int?
    let items: [InstagramStoryMedia]?
    let user: InstagramTrayUser?

    enum CodingKeys: String, CodingKey {
        case id
        case latestReelMedia = "latest_reel_media"
        case expiringAt = "expiring_at"
        case mediaCount = "media_count"
        case items
        case user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uint = try? container.decode(UInt64.self, forKey: .id) {
            id = uint
        } else if let string = try? container.decode(String.self, forKey: .id), let uint = UInt64(string) {
            id = uint
        } else {
            throw DecodingError.typeMismatch(UInt64.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Instagram reel id"))
        }
        latestReelMedia = try container.decodeIfPresent(Double.self, forKey: .latestReelMedia)
        expiringAt = try container.decodeIfPresent(Double.self, forKey: .expiringAt)
        mediaCount = try container.decodeIfPresent(Int.self, forKey: .mediaCount)
        items = try container.decodeIfPresent([InstagramStoryMedia].self, forKey: .items)
        user = try container.decodeIfPresent(InstagramTrayUser.self, forKey: .user)
    }
}

struct InstagramStoryMedia: Decodable {
    let id: String
    let pk: String?
    let takenAt: Double?
    let mediaType: Int?
    let imageVersions2: InstagramImageVersions?
    let videoVersions: [InstagramVideoVersion]?
    let videoDuration: Double?
    let storyFeedMedia: [InstagramStoryFeedMedia]?
    let storyMusicStickers: [InstagramStoryMusicSticker]?
    let reelMentions: [InstagramStoryMentionSticker]?
    let storyLinkStickers: [InstagramStoryLinkSticker]?
    let hasLiked: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case pk
        case takenAt = "taken_at"
        case mediaType = "media_type"
        case imageVersions2 = "image_versions2"
        case videoVersions = "video_versions"
        case videoDuration = "video_duration"
        case storyFeedMedia = "story_feed_media"
        case storyMusicStickers = "story_music_stickers"
        case reelMentions = "reel_mentions"
        case storyLinkStickers = "story_link_stickers"
        case hasLiked = "has_liked"
    }
}

struct InstagramImageVersions: Decodable {
    let candidates: [InstagramMediaCandidate]?
}

struct InstagramMediaCandidate: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct InstagramVideoVersion: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct InstagramStoryFeedMedia: Decodable {
    let mediaCode: String?
    let mediaType: String?
    let productType: String?

    enum CodingKeys: String, CodingKey {
        case mediaCode = "media_code"
        case mediaType = "media_type"
        case productType = "product_type"
    }

    var url: URL? {
        guard let mediaCode, !mediaCode.isEmpty else { return nil }
        if productType == "clips" || mediaType == "clips" {
            return URL(string: "https://www.instagram.com/reel/\(mediaCode)/")
        }
        return URL(string: "https://www.instagram.com/p/\(mediaCode)/")
    }

    var label: String {
        if productType == "clips" || mediaType == "clips" {
            return "Open reel"
        }
        return "Open post"
    }
}

struct InstagramStoryMusicSticker: Decodable {
    let attribution: String?
    let musicAssetInfo: InstagramStoryMusicAssetInfo?
    let startTimeMs: Double?
    let endTimeMs: Double?

    enum CodingKeys: String, CodingKey {
        case attribution
        case musicAssetInfo = "music_asset_info"
        case startTimeMs = "start_time_ms"
        case endTimeMs = "end_time_ms"
    }

    var music: InstagramStoryMusic? {
        guard let musicAssetInfo else { return nil }
        let title = musicAssetInfo.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        let artist = musicAssetInfo.displayArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = musicAssetInfo.artworkURLString
        return InstagramStoryMusic(
            title: title,
            artist: artist?.isEmpty == true ? nil : artist,
            artworkURL: artwork.flatMap(URL.init),
            duration: clipDuration ?? musicAssetInfo.duration,
        )
    }

    private var clipDuration: Double? {
        guard let startTimeMs, let endTimeMs, endTimeMs > startTimeMs else { return nil }
        return (endTimeMs - startTimeMs) / 1000
    }
}

struct InstagramStoryMusicAssetInfo: Decodable {
    let title: String?
    let displayArtist: String?
    let coverArtworkThumbnailURI: String?
    let coverArtworkURI: String?
    let coverArtworkThumbnailURL: String?
    let coverArtworkURL: String?
    let durationInMs: Double?
    let durationMs: Double?
    let audioAssetDurationMs: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case displayArtist = "display_artist"
        case coverArtworkThumbnailURI = "cover_artwork_thumbnail_uri"
        case coverArtworkURI = "cover_artwork_uri"
        case coverArtworkThumbnailURL = "cover_artwork_thumbnail_url"
        case coverArtworkURL = "cover_artwork_url"
        case durationInMs = "duration_in_ms"
        case durationMs = "duration_ms"
        case audioAssetDurationMs = "audio_asset_duration_ms"
    }

    var artworkURLString: String? {
        coverArtworkThumbnailURI ?? coverArtworkThumbnailURL ?? coverArtworkURI ?? coverArtworkURL
    }

    var duration: Double? {
        let milliseconds = durationInMs ?? durationMs ?? audioAssetDurationMs
        guard let milliseconds, milliseconds > 0 else { return nil }
        return milliseconds / 1000
    }
}

struct InstagramStoryMentionSticker: Decodable {
    let user: InstagramStoryMentionUser?

    var mention: InstagramStoryMention? {
        guard let username = user?.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return nil
        }
        return InstagramStoryMention(
            username: username,
            userId: user?.pk.map(String.init),
            url: URL(string: "https://www.instagram.com/\(username)/"),
        )
    }
}

struct InstagramStoryMentionUser: Decodable {
    let pk: UInt64?
    let username: String?
}

struct InstagramStoryLinkSticker: Decodable {
    let url: String?
    let linkTitle: String?
    let displayURL: String?

    enum CodingKeys: String, CodingKey {
        case url
        case linkTitle = "link_title"
        case displayURL = "display_url"
    }

    var link: InstagramStoryLink? {
        guard let url, let parsedURL = URL(string: url) else { return nil }
        let title = linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = displayURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels: [String?] = [title, display, parsedURL.host]
        let label = labels.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
        return InstagramStoryLink(
            title: label ?? "Open link",
            url: parsedURL,
        )
    }
}
