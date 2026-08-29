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
