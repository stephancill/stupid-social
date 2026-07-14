import Foundation

struct InstagramNewsInboxResponse: Decodable {
    let newStories: [InstagramNewsStory]?
    let oldStories: [InstagramNewsStory]?
    let priorityStories: [InstagramNewsStory]?

    enum CodingKeys: String, CodingKey {
        case newStories = "new_stories"
        case oldStories = "old_stories"
        case priorityStories = "priority_stories"
    }
}

struct InstagramNewsStory: Decodable {
    let pk: String
    let notifName: String
    let storyType: Int
    let args: InstagramNewsStoryArgs
    let counts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case pk
        case notifName = "notif_name"
        case storyType = "story_type"
        case args
        case counts
    }
}

struct InstagramNewsStoryArgs: Decodable {
    let richText: String?
    let profileId: String?
    let profileName: String?
    let profileImage: String?
    let secondProfileId: String?
    let secondProfileImage: String?
    let timestamp: Double?
    let media: [InstagramMediaThumbnail]?
    let images: [InstagramMediaThumbnail]?
    let destination: String?

    enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
        case profileId = "profile_id"
        case profileName = "profile_name"
        case profileImage = "profile_image"
        case secondProfileId = "second_profile_id"
        case secondProfileImage = "second_profile_image"
        case timestamp
        case media
        case images
        case destination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        richText = try container.decodeIfPresent(String.self, forKey: .richText)
        profileId = try container.decodeFlexibleStringIfPresent(forKey: .profileId)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        profileImage = try container.decodeIfPresent(String.self, forKey: .profileImage)
        secondProfileId = try container.decodeFlexibleStringIfPresent(forKey: .secondProfileId)
        secondProfileImage = try container.decodeIfPresent(String.self, forKey: .secondProfileImage)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        media = try container.decodeIfPresent([InstagramMediaThumbnail].self, forKey: .media)
        images = try container.decodeIfPresent([InstagramMediaThumbnail].self, forKey: .images)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
    }
}

struct InstagramMediaThumbnail: Decodable {
    let id: String
    let image: String
}

struct InstagramDirectInboxResponse: Decodable {
    let inbox: InstagramDirectInbox
    let viewer: InstagramDirectViewer?
    let status: String?
}

struct InstagramDirectViewer: Decodable {
    let pk: String
    let username: String
    let fullName: String?
    let profilePicUrl: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicUrl = "profile_pic_url"
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pk = try container.decodeFlexibleStringIfPresent(forKey: .pk) {
            self.pk = pk
        } else {
            pk = try container.decodeFlexibleString(forKey: .id)
        }
        username = try container.decode(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicUrl = try container.decodeIfPresent(String.self, forKey: .profilePicUrl)
    }
}

struct InstagramDirectInbox: Decodable {
    let threads: [InstagramDirectThread]
    let unseenCount: Int?

    enum CodingKeys: String, CodingKey {
        case threads
        case unseenCount = "unseen_count"
    }
}

struct InstagramDirectThread: Decodable {
    let threadId: String
    let threadV2Id: String?
    let threadTitle: String?
    let users: [InstagramDirectUser]
    let lastActivityAt: Int64?
    let markedAsUnread: Bool?
    let viewerId: String?
    let lastSeenAt: [String: InstagramDirectSeen]?
    let lastPermanentItem: InstagramDirectItem?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case threadV2Id = "thread_v2_id"
        case threadTitle = "thread_title"
        case users
        case lastActivityAt = "last_activity_at"
        case markedAsUnread = "marked_as_unread"
        case viewerId = "viewer_id"
        case lastSeenAt = "last_seen_at"
        case lastPermanentItem = "last_permanent_item"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decodeFlexibleString(forKey: .threadId)
        threadV2Id = try container.decodeFlexibleStringIfPresent(forKey: .threadV2Id)
        threadTitle = try container.decodeIfPresent(String.self, forKey: .threadTitle)
        users = try container.decodeIfPresent([InstagramDirectUser].self, forKey: .users) ?? []
        lastActivityAt = try container.decodeFlexibleInt64IfPresent(forKey: .lastActivityAt)
        markedAsUnread = try container.decodeIfPresent(Bool.self, forKey: .markedAsUnread)
        viewerId = try container.decodeFlexibleStringIfPresent(forKey: .viewerId)
        lastSeenAt = try container.decodeIfPresent([String: InstagramDirectSeen].self, forKey: .lastSeenAt)
        lastPermanentItem = try container.decodeIfPresent(InstagramDirectItem.self, forKey: .lastPermanentItem)
    }
}

struct InstagramDirectUser: Decodable {
    let pk: String
    let username: String?
    let fullName: String?
    let profilePicURL: String?

    enum CodingKeys: String, CodingKey {
        case pk
        case username
        case fullName = "full_name"
        case profilePicURL = "profile_pic_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pk = try container.decodeFlexibleString(forKey: .pk)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        profilePicURL = try container.decodeIfPresent(String.self, forKey: .profilePicURL)
    }
}

struct InstagramDirectSeen: Decodable {
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
    }
}

struct InstagramDirectItem: Decodable {
    let itemId: String
    let userId: String?
    let timestamp: Int64?
    let itemType: String?
    let text: String?
    let auxiliaryText: String?
    let xmaReelShare: [InstagramDirectXMA]?
    let xmaReelMention: [InstagramDirectXMA]?
    let xmaClip: [InstagramDirectXMA]?
    let xmaMediaShare: [InstagramDirectXMA]?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case userId = "user_id"
        case timestamp
        case itemType = "item_type"
        case text
        case auxiliaryText = "auxiliary_text"
        case xmaReelShare = "xma_reel_share"
        case xmaReelMention = "xma_reel_mention"
        case xmaClip = "xma_clip"
        case xmaMediaShare = "xma_media_share"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decodeFlexibleString(forKey: .itemId)
        userId = try container.decodeFlexibleStringIfPresent(forKey: .userId)
        timestamp = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
        itemType = try container.decodeIfPresent(String.self, forKey: .itemType)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        auxiliaryText = try container.decodeIfPresent(String.self, forKey: .auxiliaryText)
        xmaReelShare = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaReelShare)
        xmaReelMention = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaReelMention)
        xmaClip = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaClip)
        xmaMediaShare = try container.decodeIfPresent([InstagramDirectXMA].self, forKey: .xmaMediaShare)
    }
}

struct InstagramDirectXMA: Decodable {
    let previewURL: String?
    let targetURL: String?
    let titleText: String?
    let subtitleText: String?
    let headerTitleText: String?
    let captionBodyText: String?

    enum CodingKeys: String, CodingKey {
        case previewURL = "preview_url"
        case targetURL = "target_url"
        case titleText = "title_text"
        case subtitleText = "subtitle_text"
        case headerTitleText = "header_title_text"
        case captionBodyText = "caption_body_text"
    }
}

struct InstagramStatusResponse: Decodable {
    let status: String?
}

struct InstagramErrorResponse: Decodable {
    let message: String?
    let status: String?
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let int = try? decode(Int64.self, forKey: key) { return String(int) }
        if let uint = try? decode(UInt64.self, forKey: key) { return String(uint) }
        throw DecodingError.typeMismatch(String.self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string-like value"))
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFlexibleString(forKey: key)
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let int = try? decode(Int64.self, forKey: key) { return int }
        if let string = try? decode(String.self, forKey: key) { return Int64(string) }
        return nil
    }
}

extension InstagramDirectItem {
    var isMediaShare: Bool {
        itemType == "xma_clip" || itemType == "xma_media_share"
    }
}
