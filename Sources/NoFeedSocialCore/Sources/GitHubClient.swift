import Foundation

public struct GitHubForYouFeedResponse: Equatable, Sendable {
    public let html: String
    public let etag: String?

    public init(html: String, etag: String?) {
        self.html = html
        self.etag = etag
    }
}

public enum GitHubForYouFeedResult: Equatable, Sendable {
    case feed(GitHubForYouFeedResponse)
    case notModified
}

public struct GitHubClient: Sendable {
    private let session: URLSession
    private static let feedURL = URL(string: "https://github.com/conduit/for_you_feed")!
    private static let userAgent = "NoFeedSocial/1"

    public init(session: URLSession = defaultSession) {
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    public func forYouFeed(
        credentials: GitHubCredentials,
        etag: String? = nil,
    ) async throws -> GitHubForYouFeedResult {
        var request = URLRequest(url: Self.feedURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://github.com/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookieHeader(credentials: credentials), forHTTPHeaderField: "Cookie")

        let nonce = "v2:\(UUID().uuidString.lowercased())"
        request.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce")
        request.setValue(nonce, forHTTPHeaderField: "X-Fetch-Nonce-To-Validate")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        if http.statusCode == 304 {
            return .notModified
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SourceError.notConfigured
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SourceError.serviceError("GitHub request failed (HTTP \(http.statusCode)).")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.contains("text/html"),
              let html = String(data: data, encoding: .utf8),
              !html.isEmpty
        else {
            throw SourceError.invalidResponse
        }

        return .feed(GitHubForYouFeedResponse(
            html: html,
            etag: http.value(forHTTPHeaderField: "ETag"),
        ))
    }

    private func cookieHeader(credentials: GitHubCredentials) -> String {
        [
            "user_session=\(credentials.userSession)",
            "__Host-user_session_same_site=\(credentials.sameSiteUserSession)",
            "logged_in=yes",
        ].joined(separator: "; ")
    }

    /// Resolves a fork's parent repository and returns its OpenGraph text
    /// fields (name URL, description). Public, lazy read used by fork cards.
    public func originalRepo(forFork forkName: String) async throws -> GitHubOriginalRepo {
        let forkPath = forkName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard forkPath.split(separator: "/").count == 2 else {
            throw SourceError.invalidResponse
        }
        let forkHTML = try await publicHTML(url: URL(string: "https://github.com/\(forkPath)")!)
        guard let parentPath = Self.parentPath(inForkHTML: forkHTML) else {
            throw SourceError.invalidResponse
        }

        let originalURL = URL(string: "https://github.com/\(parentPath)")!
        let originalHTML = try await publicHTML(url: originalURL)
        let name = Self.ogMeta(in: originalHTML, property: "og:url").flatMap(URL.init(string:))?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? parentPath
        let description = Self.ogMeta(in: originalHTML, property: "og:description")
        let imageURL = Self.ogMeta(in: originalHTML, property: "og:image").flatMap(URL.init(string:))

        return GitHubOriginalRepo(
            name: name,
            description: description.flatMap { Self.stripTrailingRepoSuffix($0, name: name) },
            url: originalURL,
            imageURL: imageURL,
        )
    }

    /// Fetches a repo's public page and returns its OpenGraph card (name, title,
    /// description, image). Public, lazy read so a repo detail can render the
    /// repo's own og:image instead of an avatar.
    public func repoPage(for repoName: String) async throws -> GitHubRepoDescription {
        let path = repoName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "https://github.com/\(path)")!
        let html = try await publicHTML(url: url)
        let ogURL = Self.ogMeta(in: html, property: "og:url").flatMap(URL.init(string:))
        let name = ogURL?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? path
        let title = Self.ogMeta(in: html, property: "og:title")
        let description = Self.ogMeta(in: html, property: "og:description")
            .flatMap { Self.stripTrailingRepoSuffix($0, name: name) }
        let imageURL = Self.ogMeta(in: html, property: "og:image").flatMap(URL.init(string:))
        return GitHubRepoDescription(name: name, title: title, description: description, url: url, imageURL: imageURL)
    }

    /// Fetches a user's public profile page and returns the fields the app shows
    /// on the GitHub profile detail (name, bio, location, website, follower and
    /// following counts, repo count). Public, lazy read.
    public func userPage(for username: String) async throws -> GitHubUserProfile {
        let source = username.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "https://github.com/\(source)")!
        let html = try await publicHTML(url: url)
        guard let profile = Self.userProfile(in: html, username: source) else {
            throw SourceError.invalidResponse
        }
        return profile
    }

    private func publicHTML(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8),
              !html.isEmpty
        else { throw SourceError.invalidResponse }
        return html
    }

    private static func parentPath(inForkHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"forked from\s*<a[^>]*href="/([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let value = htmlCodeDecoded(String(html[range]))
        return value.split(separator: "/").count == 2 ? value : nil
    }

    private static func ogMeta(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = #"property="\#(escaped)"[^>]*content="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return htmlCodeDecoded(String(html[range]))
    }

    private static func htmlCodeDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func stripTrailingRepoSuffix(_ description: String, name: String) -> String {
        let suffix = " - \(name)"
        guard description.hasSuffix(suffix) else { return description }
        return String(description.dropLast(suffix.count))
    }

    /// Parses a user's public profile page into the fields the app displays.
    ///
    /// - ``description``: og:description usually reads
    ///   ``"<bio>. <username> has N repositories available."`` — the bio portion
    ///   precedes the repo count and is dropped when it is just the username.
    /// - counts: the ``tab=followers`` / ``tab=following`` links carry
    ///   ``<span class="text-bold color-fg-default">23.8k</span> followers``.
    /// - `location`/website: the ``vcard-details`` ``homeLocation`` li and the
    ///   profile ``nofollow me`` link.
    static func userProfile(in html: String, username: String) -> GitHubUserProfile? {
        let avatarURL = URL(string: "https://github.com/\(username).png?size=192")
        let displayName = firstCapture(in: html, pattern: #"class="p-name vcard-fullname[^"]*"[^>]*>\s*([^<]+)\s*<"#)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var bio: String?
        var repositoryCount: Int?
        if let meta = ogMeta(in: html, property: "og:description") {
            let countPattern = #"^(.*?)\s+has\s+([0-9.,]+[kKmM]?)\s+repositories available"#
            if let matches = try? NSRegularExpression(pattern: countPattern)
                .firstMatch(in: meta, range: NSRange(meta.startIndex..., in: meta))
            {
                if let bioRange = Range(matches.range(at: 1), in: meta) {
                    bio = trimmed(String(meta[bioRange]), username: username)
                }
                if let countRange = Range(matches.range(at: 2), in: meta) {
                    repositoryCount = parseCount(String(meta[countRange]))
                }
            }
        }

        let location = firstCapture(
            in: html,
            pattern: #"itemprop="homeLocation"[^>]*>.*?<span class="p-label">\s*([^<]+)\s*</span>"#,
            options: [.dotMatchesLineSeparators],
        )
        .flatMap { trimmed($0) }
        let websiteURL = firstCapture(in: html, pattern: #"rel="nofollow me"[^>]*href="([^"]+)""#)
            .flatMap(URL.init(string:))

        let followerCount = userCount(in: html, kind: "followers")
        let followingCount = userCount(in: html, kind: "following")

        let resolvedAvatar = avatarURL ?? URL(string: "https://github.com/\(username).png")!
        return GitHubUserProfile(
            username: username,
            displayName: displayName,
            bio: bio,
            location: location,
            websiteURL: websiteURL,
            followerCount: followerCount,
            followingCount: followingCount,
            repositoryCount: repositoryCount,
            avatarURL: resolvedAvatar,
        )
    }

    private static func userCount(in html: String, kind: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: kind)
        let pattern = #"tab=(followers|following)"[^>]*>.*?<span class="text-bold[^"]*">\s*([^<]+)\s*</span>\s*\#(escaped)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 2), in: html)
        else { return nil }
        return parseCount(String(html[range]))
    }

    private static func parseCount(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        let multiplier: Double = if value.hasSuffix("k") {
            1000
        } else if value.hasSuffix("m") {
            1_000_000
        } else if value.hasSuffix("b") {
            1_000_000_000
        } else {
            1
        }
        let digits = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: "m", with: "")
            .replacingOccurrences(of: "b", with: "")
        guard let number = Double(digits) else { return nil }
        return Int(number * multiplier)
    }

    /// The og:description bio portion is ``<bio>. <username>`` (e.g.
    /// ``cypherpunk wannabe. stephancill``) — drop the trailing username and
    /// punctuation to recover just the bio.
    private static func trimmed(_ value: String, username: String? = nil) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let username {
            if text == username || text == "\(username)." { return nil }
            if text.hasSuffix(" \(username)") || text.hasSuffix(".\(username)") {
                text = String(text.dropLast(username.count + 1))
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return text.isEmpty ? nil : text
    }

    private static func firstCapture(in text: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

public struct GitHubOriginalRepo: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let url: URL
    public let imageURL: URL?

    public init(name: String, description: String?, url: URL, imageURL: URL?) {
        self.name = name
        self.description = description
        self.url = url
        self.imageURL = imageURL
    }
}

public struct GitHubRepoDescription: Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let url: URL
    public let imageURL: URL?

    public init(name: String, title: String?, description: String?, url: URL, imageURL: URL?) {
        self.name = name
        self.title = title
        self.description = description
        self.url = url
        self.imageURL = imageURL
    }
}

public struct GitHubUserProfile: Equatable, Sendable {
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let location: String?
    public let websiteURL: URL?
    public let followerCount: Int?
    public let followingCount: Int?
    public let repositoryCount: Int?
    public let avatarURL: URL

    public init(
        username: String,
        displayName: String?,
        bio: String?,
        location: String?,
        websiteURL: URL?,
        followerCount: Int?,
        followingCount: Int?,
        repositoryCount: Int?,
        avatarURL: URL,
    ) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.location = location
        self.websiteURL = websiteURL
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.repositoryCount = repositoryCount
        self.avatarURL = avatarURL
    }
}
