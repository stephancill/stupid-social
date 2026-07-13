import Foundation

enum InstagramNotificationParser {
    static func parse(
        stories: [InstagramNewsStory],
        accountId: String,
        accountUsername: String?,
        enabledCategories: Set<InstagramNotificationCategory>,
    ) -> [NotificationItem] {
        stories.compactMap { story in
            parseSingle(story: story, accountId: accountId, accountUsername: accountUsername, enabledCategories: enabledCategories)
        }
    }

    private static func parseSingle(
        story: InstagramNewsStory,
        accountId: String,
        accountUsername: String?,
        enabledCategories: Set<InstagramNotificationCategory>,
    ) -> NotificationItem? {
        guard let category = InstagramNotificationCategory.category(for: story.notifName),
              enabledCategories.contains(category)
        else {
            return nil
        }
        let type = notificationType(from: story.notifName)
        let timestamp = story.args.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let actionText = actionText(for: story.notifName)

        let parsedBlocks = parseRichTextBlocks(from: story.args.richText ?? "")
        let contentAfterColon = parseContentAfterColon(from: story.args.richText ?? "")
        let storyLikeCount = parseStoryLikeCount(notifName: story.notifName, richText: story.args.richText ?? "", blocks: parsedBlocks)

        let actors = buildActors(from: story.args, blocks: parsedBlocks)
        let text = "\(buildActorSummary(actors: actors)) \(actionText)"

        let mediaImageUrl = story.args.media?.first?.image ?? story.args.images?.first?.image
        let imageURL = mediaImageUrl.flatMap(URL.init)
        let storyURL = parseStoryURL(from: story.args.destination, accountId: accountId, accountUsername: accountUsername)
        let linkURL = storyURL ?? imageURL

        let target: NotificationTarget?
        let targetId = story.args.media?.first?.id ?? story.pk
        if let content = contentAfterColon, !content.isEmpty {
            target = NotificationTarget(
                id: targetId,
                text: content,
                url: linkURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                author: actors.first,
                postedAt: timestamp,
                likeCount: storyLikeCount,
            )
        } else if linkURL != nil || imageURL != nil {
            target = NotificationTarget(
                id: targetId,
                text: nil,
                url: linkURL,
                imageURL: imageURL,
                imageURLs: imageURL.map { [$0] } ?? [],
                postedAt: timestamp,
                likeCount: storyLikeCount,
            )
        } else {
            target = nil
        }

        return NotificationItem(
            id: "instagram:\(story.pk)",
            network: .instagram,
            accountId: accountId,
            sourceId: story.pk,
            type: type,
            timestamp: timestamp,
            text: text,
            actors: actors,
            target: target,
            parentTarget: nil,
        )
    }

    private static func notificationType(from notifName: String) -> NotificationType {
        switch notifName {
        case "user_followed":
            .follow
        case "comment":
            .reply
        case "post_like", "story_like", "comment_like":
            .reaction
        default:
            .unknown
        }
    }

    private static func actionText(for notifName: String) -> String {
        switch notifName {
        case "user_followed":
            "followed you"
        case "comment":
            "commented"
        case "post_like":
            "liked your post"
        case "story_like":
            "liked your story"
        case "comment_like":
            "liked your comment"
        default:
            ""
        }
    }

    private struct RichTextBlock {
        let username: String
        let userId: String
    }

    private static func parseRichTextBlocks(from raw: String) -> [RichTextBlock] {
        let pattern = #"\{([^|]+)\|[^|]*\|[^|]*\|user\?id=(\d+)[^}]*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        return matches.compactMap { match in
            guard let userRange = Range(match.range(at: 1), in: raw),
                  let idRange = Range(match.range(at: 2), in: raw) else { return nil }
            return RichTextBlock(username: String(raw[userRange]), userId: String(raw[idRange]))
        }
    }

    private static func parseContentAfterColon(from raw: String) -> String? {
        let stripped = stripRichTextBlocks(from: raw)
        guard let colonIndex = stripped.lastIndex(of: ":") else { return nil }
        let content = stripped[stripped.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func parseStoryLikeCount(notifName: String, richText: String, blocks: [RichTextBlock]) -> Int? {
        guard notifName == "story_like", !blocks.isEmpty else { return nil }
        let stripped = stripRichTextBlocks(from: richText)
        let pattern = #"and\s+(\d+)\s+others?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let countRange = Range(match.range(at: 1), in: stripped),
              let otherCount = Int(stripped[countRange])
        else {
            return blocks.count
        }
        return blocks.count + otherCount
    }

    private static func stripRichTextBlocks(from raw: String) -> String {
        let pattern = #"\{[^}]+\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    private static func buildActors(from args: InstagramNewsStoryArgs, blocks: [RichTextBlock]) -> [NotificationActor] {
        var actors: [NotificationActor] = []
        let avatarById = avatarMap(from: args)
        var seenIds: Set<String> = []

        for block in blocks.prefix(2) {
            let avatar = avatarById[block.userId]
            if seenIds.insert(block.userId).inserted {
                actors.append(NotificationActor(
                    id: block.userId,
                    network: .instagram,
                    username: block.username,
                    displayName: nil,
                    avatarURL: avatar.flatMap(URL.init),
                ))
            }
        }

        if actors.isEmpty, let id = args.profileId, let name = args.profileName {
            actors.append(NotificationActor(
                id: String(id),
                network: .instagram,
                username: name,
                displayName: nil,
                avatarURL: args.profileImage.flatMap(URL.init),
            ))
        }

        return actors
    }

    private static func avatarMap(from args: InstagramNewsStoryArgs) -> [String: String] {
        var map: [String: String] = [:]
        if let id = args.profileId, let image = args.profileImage {
            map[String(id)] = image
        }
        if let id = args.secondProfileId, let image = args.secondProfileImage {
            map[String(id)] = image
        }
        return map
    }

    private static func buildActorSummary(actors: [NotificationActor]) -> String {
        guard let first = actors.first, let firstName = first.username else { return "Someone" }
        let remainingCount = actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }

    private static func parseStoryURL(
        from destination: String?,
        accountId: String,
        accountUsername: String?,
    ) -> URL? {
        guard let destination else { return nil }
        guard let questionIndex = destination.firstIndex(of: "?") else { return nil }
        let query = String(destination[destination.index(after: questionIndex)...])
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instagram.com"
        components.query = query
        guard let parsedQuery = components.queryItems else { return nil }
        guard let reelId = parsedQuery.first(where: { $0.name == "reel_id" })?.value?.removingPercentEncoding else { return nil }
        guard let feedItemId = parsedQuery.first(where: { $0.name == "feeditem_id" })?.value else { return nil }

        let mediaId = feedItemId.split(separator: "_").first.map(String.init) ?? feedItemId

        // Active stories: reel_id is the user's own numeric FID (e.g. "70150151668")
        if reelId == accountId {
            let profile = accountUsername ?? reelId
            return URL(string: "https://www.instagram.com/stories/\(profile)/\(mediaId)/")
        }

        // Archived stories: reel_id has "archiveDay:" prefix
        if reelId.hasPrefix("archiveDay:") {
            let hash = String(reelId.dropFirst("archiveDay:".count))
            return URL(string: "https://www.instagram.com/stories/archive/\(hash)/?initial_media_id=\(mediaId)")
        }

        // Highlight stories or other reel types
        return URL(string: "https://www.instagram.com/stories/archive/\(reelId)/?initial_media_id=\(mediaId)")
    }
}
