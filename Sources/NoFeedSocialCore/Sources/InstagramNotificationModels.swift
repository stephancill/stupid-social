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

struct InstagramStatusResponse: Decodable {
    let status: String?
}

struct InstagramDeleteMediaResponse: Decodable {
    let status: String?
    let didDelete: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case didDelete = "did_delete"
    }
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
}
