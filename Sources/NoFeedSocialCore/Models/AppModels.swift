import Foundation

public enum SocialNetwork: String, Codable, CaseIterable, Identifiable, Sendable {
    case x
    case farcaster
    case instagram
    case spotify
    case debug

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .x: "X"
        case .farcaster: "Farcaster"
        case .instagram: "Instagram"
        case .spotify: "Spotify"
        case .debug: "Debug"
        }
    }
}

public enum NotificationType: String, Codable, CaseIterable, Sendable {
    case mention
    case reply
    case reaction
    case follow
    case music
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
    public let timestamp: Date?

    public init(id: String, network: SocialNetwork, username: String?, displayName: String?, avatarURL: URL?, timestamp: Date? = nil) {
        self.id = id
        self.network = network
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.timestamp = timestamp
    }
}

public struct NotificationTarget: Hashable, Codable, Sendable {
    public let id: String
    public let text: String?
    public let url: URL?
    public let imageURL: URL?
    public let album: String?
    public let musicAnimation: MusicAnimationMetadata?

    public init(
        id: String,
        text: String?,
        url: URL?,
        imageURL: URL? = nil,
        album: String? = nil,
        musicAnimation: MusicAnimationMetadata? = nil
    ) {
        self.id = id
        self.text = text
        self.url = url
        self.imageURL = imageURL
        self.album = album
        self.musicAnimation = musicAnimation
    }
}

public struct MusicAnimationMetadata: Hashable, Codable, Sendable {
    public let tempo: Double?
    public let tempoConfidence: Double?
    public let loudness: Double?
    public let mode: Int?

    public init(tempo: Double?, tempoConfidence: Double?, loudness: Double?, mode: Int?) {
        self.tempo = tempo
        self.tempoConfidence = tempoConfidence
        self.loudness = loudness
        self.mode = mode
    }
}

public struct DisplayNotificationItem: Identifiable, Hashable {
    public let item: NotificationItem
    public let isUnread: Bool

    public var id: String {
        item.id
    }

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
    public let bio: String?
    public let avatarURL: URL?
    public let followerCount: Int?
    public let followingCount: Int?
    public let postsCount: Int?
    public let joinedAt: Date?
    public let websiteURL: URL?
    public let isVerified: Bool?
    public let isMutualFollow: Bool?

    public init(
        id: String,
        network: SocialNetwork,
        username: String?,
        displayName: String?,
        bio: String? = nil,
        avatarURL: URL?,
        followerCount: Int?,
        followingCount: Int?,
        postsCount: Int? = nil,
        joinedAt: Date? = nil,
        websiteURL: URL? = nil,
        isVerified: Bool? = nil,
        isMutualFollow: Bool? = nil
    ) {
        self.id = id
        self.network = network
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.avatarURL = avatarURL
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.postsCount = postsCount
        self.joinedAt = joinedAt
        self.websiteURL = websiteURL
        self.isVerified = isVerified
        self.isMutualFollow = isMutualFollow
    }
}

public struct InstagramStoryReel: Identifiable, Hashable, Sendable {
    public let id: String
    public let user: NotificationActor
    public let slides: [InstagramStorySlide]
    public let isSeen: Bool

    public init(id: String, user: NotificationActor, slides: [InstagramStorySlide], isSeen: Bool = false) {
        self.id = id
        self.user = user
        self.slides = slides
        self.isSeen = isSeen
    }
}

public struct InstagramStorySlide: Identifiable, Hashable, Sendable {
    public let id: String
    public let imageURL: URL
    public let videoURL: URL?
    public let isVideo: Bool
    public let videoDuration: Double?
    public let embedURL: URL?
    public let embedLabel: String?
    public let music: InstagramStoryMusic?
    public let ownerId: String
    public let takenAt: Double

    public init(
        id: String,
        imageURL: URL,
        videoURL: URL?,
        isVideo: Bool,
        videoDuration: Double? = nil,
        embedURL: URL? = nil,
        embedLabel: String? = nil,
        music: InstagramStoryMusic? = nil,
        ownerId: String = "",
        takenAt: Double = 0
    ) {
        self.id = id
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.isVideo = isVideo
        self.videoDuration = videoDuration
        self.embedURL = embedURL
        self.embedLabel = embedLabel
        self.music = music
        self.ownerId = ownerId
        self.takenAt = takenAt
    }
}

public struct InstagramStoryMusic: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let artworkURL: URL?

    public init(title: String, artist: String?, artworkURL: URL?) {
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
    }
}

public enum StoryBarItem: Identifiable, Hashable, Sendable {
    case instagram(InstagramStoryReel)
    case spotify(SpotifyActivityItem)

    public var id: String {
        switch self {
        case let .instagram(reel): "ig-\(reel.id)"
        case let .spotify(item): "sp-\(item.userURI)"
        }
    }

    public var timestamp: Date {
        switch self {
        case let .instagram(reel):
            Date(timeIntervalSince1970: reel.slides.first?.takenAt ?? 0)
        case let .spotify(item): item.timestamp
        }
    }

    public var isSeen: Bool {
        switch self {
        case let .instagram(reel): reel.isSeen
        case let .spotify(item): item.isSeen
        }
    }

    public var userAvatarURL: URL? {
        switch self {
        case let .instagram(reel): reel.user.avatarURL
        case let .spotify(item): item.userAvatarURL
        }
    }

    public var userName: String {
        switch self {
        case let .instagram(reel): reel.user.username ?? reel.user.displayName ?? ""
        case let .spotify(item): item.userName
        }
    }

    public var network: SocialNetwork {
        switch self {
        case .instagram: .instagram
        case .spotify: .spotify
        }
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

public struct SpotifyActivityItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let timestamp: Date
    public let userName: String
    public let userURI: String
    public let userAvatarURL: URL?
    public let trackName: String
    public let artistName: String?
    public let albumName: String?
    public let trackURI: String
    public let trackURL: URL?
    public let imageURL: URL?
    public let musicAnimation: MusicAnimationMetadata?
    public let isSeen: Bool

    public init(
        id: String,
        timestamp: Date,
        userName: String,
        userURI: String,
        userAvatarURL: URL?,
        trackName: String,
        artistName: String?,
        albumName: String?,
        trackURI: String,
        trackURL: URL?,
        imageURL: URL?,
        musicAnimation: MusicAnimationMetadata?,
        isSeen: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userName = userName
        self.userURI = userURI
        self.userAvatarURL = userAvatarURL
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.trackURI = trackURI
        self.trackURL = trackURL
        self.imageURL = imageURL
        self.musicAnimation = musicAnimation
        self.isSeen = isSeen
    }
}
