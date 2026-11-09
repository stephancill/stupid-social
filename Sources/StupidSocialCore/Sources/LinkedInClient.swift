import Foundation
import Synchronization

/// The session cookies www.linkedin.com's web client sends, from the web login (`LinkedInLoginWebView`).
public struct LinkedInCredentials: Codable, Equatable, Sendable {
    /// The `li_at` session cookie.
    public let liAt: String
    /// The `JSESSIONID` cookie without its quotes; it doubles as the `csrf-token` header.
    public let jsessionId: String

    public init(liAt: String, jsessionId: String) {
        self.liAt = liAt
        self.jsessionId = jsessionId.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// The session in a web login's cookies. LinkedIn sets `JSESSIONID` before login too; `li_at` only once signed in.
    public init?(cookies: [HTTPCookie]) {
        let values = Dictionary(
            cookies.filter { $0.domain.hasSuffix("linkedin.com") }.map { ($0.name, $0.value) },
            uniquingKeysWith: { _, latest in latest },
        )
        guard let liAt = values["li_at"], !liAt.isEmpty, let session = values["JSESSIONID"], !session.isEmpty else { return nil }
        self.init(liAt: liAt, jsessionId: session)
    }
}

/// The signed-in member.
public struct LinkedInMe: Sendable {
    /// `urn:li:fsd_profile:<id>`, which is also the messaging mailbox.
    public let profileUrn: String
    public let publicIdentifier: String?
    public let name: String
    public let avatarURL: URL?
}

enum LinkedInError: LocalizedError {
    case http(status: Int)
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case let .http(status): "LinkedIn answered \(status)."
        case let .graphQL(message): "LinkedIn: \(message)"
        }
    }
}

/// LinkedIn's Voyager API as www.linkedin.com's web client calls it: the `li_at` and `JSESSIONID` cookies, the
/// JSESSIONID again as `csrf-token`, Rest.li protocol 2.0 and a Chrome user agent (validated with
/// `scripts/linkedin-web-client.py`, observed 2026-11-09). Notifications are Voyager REST; messaging is the messenger
/// SDK's GraphQL queries and Rest.li actions.
public final class LinkedInClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://www.linkedin.com")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
    static let normalizedJSON = "application/vnd.linkedin.normalized+json+2.1"

    /// Messaging SDK query ids, from the web bundle (`kind:"query",id:"messengerMessages.<hash>"`, observed 2026-11-09).
    enum Query {
        /// (query, count, mailboxUrn, nextCursor?): one category of the inbox, newest first.
        static let conversationsByCategory = "messengerConversations.9501074288a12f3ae9e3c7ea243bccbf"
        /// (messengerConversationsId, count).
        static let conversationById = "messengerConversations.fb3eab135970d880d59c5fad1bc695f9"
        /// (conversationUrn): the newest messages, newest first.
        static let messagesSync = "messengerMessages.5846eeb71c981f11e0134cb6626cc314"
        /// (deliveredAt, conversationUrn, countBefore, countAfter): the messages before a time, oldest first.
        static let messagesByTimestamp = "messengerMessages.d8ea76885a52fd5dc5c317078ab7c977"
    }

    static let notificationsDecoration = "com.linkedin.voyager.dash.deco.identity.notifications.CardsCollectionWithInjectionsNoPills-25"
    static let primaryInbox = "(predicateUnions:List((conversationCategoryPredicate:(category:PRIMARY_INBOX))))"

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    private let cachedMe = Mutex<LinkedInMe?>(nil)

    public init(credentialStore: KeychainCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    func credentials() throws -> LinkedInCredentials {
        guard let credentials = try credentialStore.loadLinkedInCredentials(), !credentials.liAt.isEmpty else { throw SourceError.notConfigured }
        return credentials
    }

    // MARK: Profile

    /// The signed-in member, which also checks the cookies. Kept after the first answer, as it doesn't change.
    public func me(credentials: LinkedInCredentials? = nil) async throws -> LinkedInMe {
        if credentials == nil, let cached = cachedMe.withLock({ $0 }) { return cached }
        let data = try await send("GET", "/voyager/api/me", accept: Self.normalizedJSON, credentials: credentials)
        let me = try LinkedInParser.me(from: data)
        cachedMe.withLock { $0 = me }
        return me
    }

    // MARK: Notifications

    /// The Notifications tab's cards, newest first. Reading them doesn't mark them seen.
    func notificationCards(count: Int = 20) async throws -> [LinkedInNotificationCard] {
        let data = try await send(
            "GET",
            "/voyager/api/voyagerIdentityDashNotificationCards",
            query: "decorationId=\(Self.notificationsDecoration)&count=\(count)&q=filterVanityName&start=0",
            accept: Self.normalizedJSON,
        )
        return try LinkedInParser.notificationCards(from: data)
    }

    // MARK: Messaging reads

    /// One page of the primary inbox, newest first, and the cursor to the next.
    func conversations(cursor: String? = nil) async throws -> (conversations: [LinkedInConversation], nextCursor: String?) {
        let mailbox = try await me().profileUrn
        let anchor = cursor.map { ",nextCursor:\($0)" } ?? ""
        let response: LinkedInGraphQL<LinkedInConversationsData> = try await graphQL(
            Query.conversationsByCategory,
            variables: "(query:\(Self.primaryInbox),count:20,mailboxUrn:\(Self.restli(mailbox))\(anchor))",
        )
        let page = response.data.messengerConversationsByCategoryQuery
        return (page.elements, page.metadata?.nextCursor)
    }

    func conversation(urn: String) async throws -> LinkedInConversation {
        let response: LinkedInGraphQL<LinkedInConversationData> = try await graphQL(
            Query.conversationById,
            variables: "(messengerConversationsId:\(Self.restli(urn)),count:1)",
        )
        return response.data.messengerConversationsById
    }

    /// The newest messages, newest first.
    func messages(conversationUrn: String) async throws -> [LinkedInMessage] {
        let response: LinkedInGraphQL<LinkedInMessagesSyncData> = try await graphQL(
            Query.messagesSync,
            variables: "(conversationUrn:\(Self.restli(conversationUrn)))",
        )
        return response.data.messengerMessagesBySyncToken.elements
    }

    /// Up to `count` messages delivered before `before`, oldest first; `hasMore` is false at the conversation's start.
    func messages(conversationUrn: String, before: Date, count: Int = 20) async throws -> (messages: [LinkedInMessage], hasMore: Bool) {
        let response: LinkedInGraphQL<LinkedInMessagesByTimeData> = try await graphQL(
            Query.messagesByTimestamp,
            variables: "(deliveredAt:\(Self.milliseconds(before)),conversationUrn:\(Self.restli(conversationUrn)),countBefore:\(count),countAfter:0)",
        )
        let page = response.data.messengerMessagesByAnchorTimestamp
        return (page.elements, page.metadata?.prevCursor != nil && !page.elements.isEmpty)
    }

    // MARK: Messaging writes

    /// Sends text, quoting `replyTo` in full as the web composer does (`repliedMessageContent`).
    func send(conversationUrn: String, text: String, replyTo: LinkedInMessage?) async throws -> LinkedInSentMessage {
        let mailbox = try await me().profileUrn
        var render: [[String: Any]] = []
        if let replyTo {
            render.append(["repliedMessageContent": [
                "originalSenderUrn": replyTo.sender.entityUrn,
                "originalSendAt": Self.milliseconds(replyTo.deliveredAt),
                "originalMessageUrn": replyTo.entityUrn,
                "messageBody": ["text": replyTo.body?.text ?? "", "attributes": [] as [Any]],
            ]])
        }
        let body: [String: Any] = [
            "message": [
                "body": ["attributes": [] as [Any], "text": text],
                "renderContentUnions": render,
                "conversationUrn": conversationUrn,
                "originToken": UUID().uuidString.lowercased(),
            ],
            "mailboxUrn": mailbox,
            "trackingId": Self.trackingId(),
            "dedupeByClientGeneratedToken": false,
        ]
        let data = try await send("POST", "/voyager/api/voyagerMessagingDashMessengerMessages", query: "action=createMessage", body: body)
        do {
            return try JSONDecoder().decode(LinkedInSentResponse.self, from: data).value
        } catch {
            throw SourceError.invalidResponse
        }
    }

    func setReaction(messageUrn: String, emoji: String, remove: Bool) async throws {
        _ = try await send(
            "POST", "/voyager/api/voyagerMessagingDashMessengerMessages",
            query: "action=\(remove ? "unreactWithEmoji" : "reactWithEmoji")",
            body: ["messageUrn": messageUrn, "emoji": emoji],
        )
    }

    func edit(messageUrn: String, text: String) async throws {
        _ = try await send(
            "POST", "/voyager/api/voyagerMessagingDashMessengerMessages/\(Self.restli(messageUrn))",
            body: ["patch": ["$set": ["body": ["attributes": [] as [Any], "text": text]]]],
        )
    }

    /// Unsends the message for everyone; it stays in the history as `RECALLED`.
    func recall(messageUrn: String) async throws {
        _ = try await send("POST", "/voyager/api/voyagerMessagingDashMessengerMessages", query: "action=recall", body: ["messageUrn": messageUrn])
    }

    /// LinkedIn keeps read state per conversation, not per message.
    func setRead(conversationUrn: String, read: Bool = true) async throws {
        _ = try await send(
            "POST", "/voyager/api/voyagerMessagingDashMessengerConversations",
            query: "ids=List(\(Self.restli(conversationUrn)))",
            body: ["entities": [conversationUrn: ["patch": ["$set": ["read": read]]]]],
        )
    }

    func sendTyping(conversationUrn: String) async throws {
        _ = try await send("POST", "/voyager/api/voyagerMessagingDashMessengerConversations", query: "action=typing", body: ["conversationUrn": conversationUrn])
    }

    // MARK: Transport

    private func graphQL<T: Decodable>(_ queryId: String, variables: String) async throws -> T {
        let data = try await send(
            "GET", "/voyager/api/voyagerMessagingGraphQL/graphql",
            query: "queryId=\(queryId)&variables=\(variables)",
            accept: "application/graphql",
        )
        if let errors = try? JSONDecoder().decode(LinkedInGraphQLErrors.self, from: data), let first = errors.errors?.first {
            throw LinkedInError.graphQL(first.message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SourceError.invalidResponse
        }
    }

    /// `query` is already percent-encoded. A signed-out session redirects to the login page, which is not followed.
    private func send(_ method: String, _ path: String, query: String? = nil, accept: String = "application/json", body: [String: Any]? = nil, credentials: LinkedInCredentials? = nil) async throws -> Data {
        let credentials = try credentials ?? self.credentials()
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in Self.headers(credentials: credentials, accept: accept) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request, delegate: LinkedInNoRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300:
            return data
        case 300 ..< 400, 401:
            throw SourceError.notConfigured
        default:
            throw LinkedInError.http(status: status)
        }
    }

    static func headers(credentials: LinkedInCredentials, accept: String) -> [String: String] {
        [
            "Cookie": "li_at=\(credentials.liAt); JSESSIONID=\"\(credentials.jsessionId)\"",
            "csrf-token": credentials.jsessionId,
            "Accept": accept,
            "x-restli-protocol-version": "2.0.0",
            "x-li-lang": "en_US",
            "User-Agent": userAgent,
        ]
    }

    /// A URN as a Rest.li value inside `variables=(…)` or a path: everything but unreserved characters escaped.
    static func restli(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 16 random bytes as the web client sends them: each byte as one character.
    static func trackingId() -> String {
        String((0 ..< 16).map { _ in Character(Unicode.Scalar(UInt8.random(in: 0 ... 255))) })
    }
}

/// Stops redirects, so an expired session's redirect to the login page reads as signed out.
private final class LinkedInNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = LinkedInNoRedirects()

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest) async -> URLRequest? {
        nil
    }
}
