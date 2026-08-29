import Foundation

@MainActor
public final class GitHubActivitySource: GitHubActivityFetching, AccountValidating {
    public let network: SocialNetwork = .github

    private let client: GitHubClient
    private let credentialStore: KeychainCredentialStore
    private let metadataStore: AccountMetadataStore

    public init(client: GitHubClient, credentialStore: KeychainCredentialStore, metadataStore: AccountMetadataStore) {
        self.client = client
        self.credentialStore = credentialStore
        self.metadataStore = metadataStore
    }

    public func validateAccount() async throws -> AccountStatus {
        guard let credentials = try credentialStore.loadGitHubCredentials() else {
            return .notConfigured
        }
        do {
            _ = try await fetch(credentials: credentials)
            return .valid
        } catch SourceError.notConfigured {
            markInvalid()
            return .invalidCredentials
        } catch {
            return .serviceError(error.localizedDescription)
        }
    }

    public func fetchGitHubActivity(reason _: RefreshReason) async throws -> [GitHubActivityGroup] {
        guard let credentials = try credentialStore.loadGitHubCredentials() else { return [] }
        return try await fetch(credentials: credentials)
    }

    private func fetch(credentials: GitHubCredentials) async throws -> [GitHubActivityGroup] {
        let result = try await client.forYouFeed(credentials: credentials)
        guard case let .feed(response) = result else { return [] }
        return try GitHubActivityParser.parse(response.html)
    }

    private func markInvalid() {
        guard var account = metadataStore.githubAccount else { return }
        account.status = .invalidCredentials
        metadataStore.githubAccount = account
    }
}

public enum GitHubActivityParser {
    private struct CardKey: Hashable {
        let type: String
        let recordId: String
    }

    private struct ParsedCard {
        var metadata: FeedCard
        var actions: [Action] = []
    }

    private struct Action {
        let target: String?
        let metadata: ClickMetadata?
        let url: URL?
    }

    private struct HydroEnvelope: Decodable {
        let payload: Payload
    }

    private struct Payload: Decodable {
        let feedCard: FeedCard?
        let clickTarget: String?
        let metadata: ClickMetadata?

        enum CodingKeys: String, CodingKey {
            case feedCard = "feed_card"
            case clickTarget = "click_target"
            case metadata
        }
    }

    private struct FeedCard: Decodable {
        let cardType: String
        let createdAt: String
        let recordId: FlexibleId
        let resourceType: String
        let resourceId: FlexibleId
        let cardPosition: Int?
        let cardSubPosition: Int?

        enum CodingKeys: String, CodingKey {
            case cardType = "card_type"
            case createdAt = "created_at"
            case recordId = "record_id"
            case resourceType = "resource_type"
            case resourceId = "resource_id"
            case cardPosition = "card_position"
            case cardSubPosition = "card_sub_position"
        }
    }

    private struct ClickMetadata: Decodable {
        let clickedResourceType: String
        let clickedResourceId: FlexibleId

        enum CodingKeys: String, CodingKey {
            case clickedResourceType = "clicked_resource_type"
            case clickedResourceId = "clicked_resource_id"
        }
    }

    private struct FlexibleId: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let integer = try? container.decode(Int64.self) {
                value = String(integer)
            } else {
                throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer id"))
            }
        }
    }

    public static func parse(_ html: String) throws -> [GitHubActivityGroup] {
        let tagPattern = #"<[^>]+data-hydro-(view|click)="([^"]+)"[^>]*>"#
        let regex = try NSRegularExpression(pattern: tagPattern)
        let range = NSRange(html.startIndex..., in: html)
        let hiddenRanges = try hiddenRollupRanges(in: html)
        let repoDetails = try repoMetadata(in: html)
        var cards: [CardKey: ParsedCard] = [:]
        var order: [CardKey] = []
        let decoder = JSONDecoder()

        for match in regex.matches(in: html, range: range) {
            guard !hiddenRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
            guard let kindRange = Range(match.range(at: 1), in: html),
                  let jsonRange = Range(match.range(at: 2), in: html),
                  let tagRange = Range(match.range(at: 0), in: html)
            else { continue }
            let kind = String(html[kindRange])
            let encodedJSON = String(html[jsonRange])
            guard let data = htmlDecoded(encodedJSON).data(using: .utf8),
                  let envelope = try? decoder.decode(HydroEnvelope.self, from: data),
                  let card = envelope.payload.feedCard
            else { continue }

            let key = CardKey(type: card.cardType, recordId: card.recordId.value)
            if cards[key] == nil {
                cards[key] = ParsedCard(metadata: card)
            }
            if kind == "view", !order.contains(key) {
                order.append(key)
            }
            guard kind == "click" else { continue }
            let tag = String(html[tagRange])
            cards[key]?.actions.append(Action(
                target: envelope.payload.clickTarget,
                metadata: envelope.payload.metadata,
                url: href(in: tag),
            ))
        }

        let normalized = order.compactMap { key -> (item: GitHubActivityItem, position: Int?, subPosition: Int?)? in
            guard let card = cards[key], let item = normalize(card) else { return nil }
            return (item, card.metadata.cardPosition, card.metadata.cardSubPosition)
        }
        var actorByFollowResourceId: [String: NotificationActor] = [:]
        var actorByRollupPosition: [Int: NotificationActor] = [:]
        for entry in normalized where entry.item.actor.username != nil {
            if entry.item.kind == .followed {
                actorByFollowResourceId[entry.item.actor.id] = entry.item.actor
            }
            if entry.subPosition == 0, let position = entry.position {
                actorByRollupPosition[position] = entry.item.actor
            }
        }

        let complete = normalized.compactMap { entry -> GitHubActivityItem? in
            let item = entry.item
            let actor = entry.position.flatMap { actorByRollupPosition[$0] }
                ?? (item.actor.username == nil ? actorByFollowResourceId[item.actor.id] : item.actor)
            guard let actor, actor.username != nil else { return nil }
            var updated = item.replacingActor(actor)
            if item.kind == .starredRepository || item.kind == .forkedRepository {
                if let detail = repoDetails[item.targetName] {
                    updated = updated.withRepoMetadata(detail)
                }
            } else if item.kind == .followed,
                      let meta = followUserMetadata(for: item.targetName, in: html)
            {
                updated = updated.withFollowUserMetadata(meta)
            }
            return updated
        }

        let grouped = Dictionary(grouping: complete, by: { $0.actor.id })
        return grouped.values.compactMap { activities in
            guard let actor = activities.first?.actor else { return nil }
            return GitHubActivityGroup(actor: actor, activities: activities.sorted { $0.timestamp < $1.timestamp })
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private static func normalize(_ card: ParsedCard) -> GitHubActivityItem? {
        let metadata = card.metadata
        let kind = GitHubActivityKind(rawValue: metadata.cardType) ?? .unknown
        guard let timestamp = githubDate(metadata.createdAt) else { return nil }

        let actorId: String
        let actorAction: Action?
        let targetId: String
        let targetAction: Action?
        switch kind {
        case .followed:
            actorId = metadata.resourceId.value
            actorAction = action(in: card.actions, type: "USER", id: actorId)
            targetId = metadata.recordId.value
            targetAction = action(in: card.actions, type: "USER", id: targetId)
        case .starredRepository, .forkedRepository:
            guard let userAction = action(in: card.actions, type: "USER") else { return nil }
            actorId = userAction.metadata?.clickedResourceId.value ?? ""
            actorAction = userAction
            targetId = metadata.resourceId.value
            targetAction = action(in: card.actions, type: "REPO", id: targetId)
        case .unknown:
            return nil
        }

        guard let targetURL = targetAction?.url else { return nil }
        let actorName = actorAction?.url?.pathComponents.dropFirst().first
        let actor = NotificationActor(
            id: actorId,
            network: .github,
            username: actorName,
            displayName: nil,
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/\(actorId)?s=160&v=4"),
        )
        let targetName = targetURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetAvatarURL: URL? = switch kind {
        case .followed:
            URL(string: "https://avatars.githubusercontent.com/u/\(targetId)?s=192&v=4")
        case .starredRepository, .forkedRepository:
            targetName.split(separator: "/").first.map { owner in URL(string: "https://github.com/\(owner).png?size=192")! }
        case .unknown:
            nil
        }
        let verb = switch kind {
        case .starredRepository: "starred"
        case .followed: "followed"
        case .forkedRepository: "forked"
        case .unknown: "updated"
        }
        return GitHubActivityItem(
            id: "github-\(metadata.cardType.lowercased())-\(metadata.recordId.value)",
            kind: kind,
            timestamp: timestamp,
            actor: actor,
            targetId: targetId,
            targetName: targetName,
            targetURL: targetURL,
            targetAvatarURL: targetAvatarURL,
            summary: "\(actorName ?? "Someone") \(verb) \(targetName)",
        )
    }

    private static func action(in actions: [Action], type: String, id: String? = nil) -> Action? {
        actions.first { action in
            guard action.metadata?.clickedResourceType == type else { return false }
            return id == nil || action.metadata?.clickedResourceId.value == id
        }
    }

    private static func href(in tag: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"href="([^"]+)""#),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        let value = htmlDecoded(String(tag[range]))
        guard let url = URL(string: value, relativeTo: URL(string: "https://github.com"))?.absoluteURL,
              url.scheme == "https", url.host == "github.com"
        else { return nil }
        return url
    }

    private static func hiddenRollupRanges(in html: String) throws -> [NSRange] {
        let divRegex = try NSRegularExpression(pattern: #"<(/?)div\b[^>]*>"#, options: [.caseInsensitive])
        let fullRange = NSRange(html.startIndex..., in: html)
        var stack: [(start: Int, hidden: Bool)] = []
        var ranges: [NSRange] = []

        for match in divRegex.matches(in: html, range: fullRange) {
            guard let slashRange = Range(match.range(at: 1), in: html),
                  let tagRange = Range(match.range(at: 0), in: html)
            else { continue }
            if html[slashRange].isEmpty {
                let tag = html[tagRange]
                stack.append((match.range.location, tag.contains("Details-content--hidden")))
            } else if let opening = stack.popLast(), opening.hidden {
                ranges.append(NSRange(location: opening.start, length: NSMaxRange(match.range) - opening.start))
            }
        }
        return ranges
    }

    private static func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func githubDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    fileprivate struct GitHubRepoMetadata {
        let description: String?
        let language: String?
        let stars: String?
        let color: String?
    }

    struct GitHubFollowUserMetadata {
        let displayName: String?
        let bio: String?
        let repos: String?
        let followers: String?
    }

    private static func repoMetadata(in html: String) throws -> [String: GitHubRepoMetadata] {
        let articleRegex = try NSRegularExpression(pattern: #"<article\b"#)
        let fullRange = NSRange(html.startIndex..., in: html)
        var result: [String: GitHubRepoMetadata] = [:]

        for match in articleRegex.matches(in: html, range: fullRange) {
            let chunkStart = html.index(html.startIndex, offsetBy: match.range.location)
            guard let closeRange = html.range(of: "</article>", range: chunkStart ..< html.endIndex) else { continue }
            let chunk = String(html[chunkStart ..< closeRange.upperBound])
            guard let wbRange = chunk.range(of: "wb-break-word") else { continue }
            let after = String(chunk[wbRange.upperBound...])
            guard let rawName = firstCapture(in: after, pattern: #"text-bold"[^>]*>([^<]+)</a>"#) else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let description = firstCapture(in: chunk, pattern: #"class="Link--primary Link text[^"]*">[^<]*</a>\s*</div>\s*<div[^>]*>\s*([^<]*)"#)
                .flatMap { trimmed($0) }
            let language = firstCapture(in: chunk, pattern: #"itemprop="programmingLanguage">([^<]+)</span>"#)
                .flatMap { trimmed($0) }
            let stars = firstCapture(in: chunk, pattern: #"aria-label="([0-9.,]+[kKmM]?)\s+stargazers""#)
                .flatMap { trimmed($0) }
            let color = firstCapture(in: chunk, pattern: #"repo-language-color"[^>]*style="background-color:\s*(#[0-9A-Fa-f]{6})"#)
                .flatMap { trimmed($0) }
            result[name] = GitHubRepoMetadata(
                description: description,
                language: language,
                stars: stars,
                color: color,
            )
        }
        return result
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func firstCapture(in text: String, pattern: String, dotall: Bool) -> String? {
        let options: NSRegularExpression.Options = dotall ? [.dotMatchesLineSeparators] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// Parses the followed user's card (display name, bio, repo + follower
    /// counts) from the follow event's article, keyed by the followed username.
    static func followUserMetadata(for username: String, in html: String) -> GitHubFollowUserMetadata? {
        let escaped = NSRegularExpression.escapedPattern(for: username)
        let anchorPattern = #"href="/\#(escaped)"[^>]*class="[^"]*text-bold"[^>]*>([^<]+)</a>"#
        guard let anchorRe = try? NSRegularExpression(pattern: anchorPattern),
              let (match, chunk) = followedUserAnchor(anchorRe: anchorRe, in: html)
        else { return nil }

        let displayName = Range(match.range(at: 1), in: html).flatMap { trimmed(String(html[$0])) }

        let repos = chunk.flatMap { firstCapture(in: $0, pattern: #"([0-9.,]+[kKmM]?)\s+repositories"#) }.flatMap { trimmed($0) }
        let followers = chunk.flatMap { firstCapture(in: $0, pattern: #"([0-9.,]+[kKmM]?)\s+followers"#) }.flatMap { trimmed($0) }

        // The bio lives only inside the card's `wb-break-all` container. Parsing
        // that container (rather than everything up to the repo count) keeps the
        // `color-fg-muted` username handle and muted counts paragraph out of the
        // bio text entirely.
        var bio: String?
        if let chunk,
           let bioFragment = firstCapture(in: chunk, pattern: #"class="m-0 mt-1 wb-break-all"[^>]*>\s*<div>(.*?)</div>\s*</div>"#, dotall: true)
        {
            let cleaned = strippedFragment(bioFragment)
            bio = cleaned.isEmpty ? nil : cleaned
        }

        return GitHubFollowUserMetadata(
            displayName: displayName,
            bio: bio,
            repos: repos,
            followers: followers,
        )
    }

    /// Finds the `<a ... class="...text-bold">` link for the followed user,
    /// preferring the one inside a card that actually renders their bio. A
    /// username can also appear earlier in the document as an actor/star card,
    /// whose article has no `wb-break-all` bio container; that match must not be
    /// mistaken for the followed user's card.
    private static func followedUserAnchor(anchorRe: NSRegularExpression, in html: String) -> (result: NSTextCheckingResult, chunk: String?)? {
        let ns = html as NSString
        let fullRange = NSRange(html.startIndex..., in: html)
        var fallback: NSTextCheckingResult?
        var fallbackChunk: String?
        for match in anchorRe.matches(in: html, range: fullRange) {
            let anchorStart = match.range.location
            let regionStart = ns.range(of: "<article", options: .backwards, range: NSRange(location: 0, length: anchorStart)).location
            let regionEnd = ns.range(of: "</article>", range: NSRange(location: anchorStart, length: ns.length - anchorStart)).location + "</article>".count
            guard regionStart != NSNotFound, regionEnd > regionStart else { continue }
            let chunk = Range(NSRange(location: regionStart, length: regionEnd - regionStart), in: html).map { String(html[$0]) }
            if fallback == nil {
                fallback = match
                fallbackChunk = chunk
            }
            if let chunk, chunk.contains(#"class="m-0 mt-1 wb-break-all""#) {
                return (match, chunk)
            }
        }
        guard let fallback else { return nil }
        return (fallback, fallbackChunk)
    }

    private static func strippedFragment(_ fragment: String) -> String {
        let stripped = (try? NSRegularExpression(pattern: "<[^>]+>"))?
            .stringByReplacingMatches(in: fragment, options: [], range: NSRange(fragment.startIndex..., in: fragment), withTemplate: " ") ?? fragment
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        let decoded = entities.reduce(stripped) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension GitHubActivityItem {
    func replacingActor(_ actor: NotificationActor) -> GitHubActivityItem {
        let verb = switch kind {
        case .starredRepository: "starred"
        case .followed: "followed"
        case .forkedRepository: "forked"
        case .unknown: "updated"
        }
        return GitHubActivityItem(
            id: id,
            kind: kind,
            timestamp: timestamp,
            actor: actor,
            targetId: targetId,
            targetName: targetName,
            targetURL: targetURL,
            targetAvatarURL: targetAvatarURL,
            summary: "\(actor.username ?? "Someone") \(verb) \(targetName)",
            repoDescription: repoDescription,
            repoLanguage: repoLanguage,
            repoStars: repoStars,
            repoLanguageColor: repoLanguageColor,
            followUserDisplayName: followUserDisplayName,
            followUserBio: followUserBio,
            followUserRepos: followUserRepos,
            followUserFollowers: followUserFollowers,
        )
    }

    func withRepoMetadata(_ metadata: GitHubActivityParser.GitHubRepoMetadata) -> GitHubActivityItem {
        GitHubActivityItem(
            id: id,
            kind: kind,
            timestamp: timestamp,
            actor: actor,
            targetId: targetId,
            targetName: targetName,
            targetURL: targetURL,
            targetAvatarURL: targetAvatarURL,
            summary: summary,
            repoDescription: metadata.description,
            repoLanguage: metadata.language,
            repoStars: metadata.stars,
            repoLanguageColor: metadata.color,
            followUserDisplayName: followUserDisplayName,
            followUserBio: followUserBio,
            followUserRepos: followUserRepos,
            followUserFollowers: followUserFollowers,
        )
    }

    func withFollowUserMetadata(_ metadata: GitHubActivityParser.GitHubFollowUserMetadata) -> GitHubActivityItem {
        GitHubActivityItem(
            id: id,
            kind: kind,
            timestamp: timestamp,
            actor: actor,
            targetId: targetId,
            targetName: targetName,
            targetURL: targetURL,
            targetAvatarURL: targetAvatarURL,
            summary: summary,
            repoDescription: repoDescription,
            repoLanguage: repoLanguage,
            repoStars: repoStars,
            followUserDisplayName: metadata.displayName,
            followUserBio: metadata.bio,
            followUserRepos: metadata.repos,
            followUserFollowers: metadata.followers,
        )
    }
}
