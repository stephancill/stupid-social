import Foundation

// Instagram Direct through the web inbox's GraphQL operations ("IGD Off-Msys"). The `direct_v2` REST inbox
// answers 404 with a logged-out page for accounts on the new web inbox. Users and messages carry two ids: the
// Instagram user id (`igid`) and the messaging id (`interop_messaging_user_fbid` / `sender_fbid`).

struct InstagramDirectMailbox: Decodable {
    let id: String
    let threadsByFolder: InstagramDirectThreadConnection
}

struct InstagramDirectThreadConnection: Decodable {
    struct Edge: Decodable {
        struct Node: Decodable {
            let asIgDirectThread: InstagramDirectThread?
        }

        let node: Node
    }

    let edges: [Edge]
    let pageInfo: InstagramDirectPageInfo

    var threads: [InstagramDirectThread] {
        edges.compactMap(\.node.asIgDirectThread)
    }
}

struct InstagramDirectPageInfo: Decodable {
    let endCursor: String?
    let hasNextPage: Bool?
}

struct InstagramDirectThread: Decodable {
    struct Viewer: Decodable {
        let id: String?
        let interopMessagingUserFbid: String?
        let profilePicUrl: String?
    }

    struct ReadReceipt: Decodable {
        let participantFbid: String
        let watermarkTimestampMs: String?
    }

    /// The id the web uses in `/direct/t/<thread_fbid>/` and for sending.
    let threadFbid: String
    /// The legacy `340282366841710…` thread id, which the read mutation takes.
    let threadId: String?
    let threadTitle: String?
    let isGroup: Bool?
    let markedAsUnread: Bool?
    let threadImageUrl: String?
    let users: [InstagramDirectUser]?
    let viewer: Viewer?
    let slideReadReceipts: [ReadReceipt]?
    /// Newest first.
    let slideMessages: InstagramDirectMessageConnection?

    var messages: [InstagramDirectMessage] {
        slideMessages?.edges.map(\.node) ?? []
    }

    var viewerFbid: String? {
        viewer?.interopMessagingUserFbid
    }

    /// When the viewer last read the thread.
    var viewerReadAt: Date? {
        guard let viewerFbid,
              let receipt = slideReadReceipts?.first(where: { $0.participantFbid == viewerFbid })
        else { return nil }
        return instagramDirectDate(receipt.watermarkTimestampMs)
    }

    /// Others' messages newer than the viewer's read receipt, among the loaded ones.
    var unreadMessages: [InstagramDirectMessage] {
        let readAt = viewerReadAt ?? .distantPast
        return messages.filter { $0.senderFbid != viewerFbid && ($0.sentAt ?? .distantPast) > readAt }
    }

    /// The other people in the thread; `users` leaves out the viewer.
    var others: [InstagramDirectUser] {
        (users ?? []).filter { $0.interopMessagingUserFbid != viewerFbid }
    }
}

struct InstagramDirectUser: Decodable {
    /// The Instagram user id.
    let id: String
    let interopMessagingUserFbid: String?
    let username: String?
    let fullName: String?
    let profilePicUrl: String?
}

struct InstagramDirectMessageConnection: Decodable {
    struct Edge: Decodable {
        let node: InstagramDirectMessage
    }

    let edges: [Edge]
    let pageInfo: InstagramDirectPageInfo?
}

struct InstagramDirectMessage: Codable {
    struct Reaction: Codable {
        let reaction: String
        let senderFbid: String
    }

    struct Sender: Codable {
        struct UserDict: Codable {
            let username: String?
            let profilePicUrl: String?
        }

        let id: String?
        let name: String?
        let userDict: UserDict?
    }

    /// `mid.$…`, the same as `message_id`, which inbox messages leave out.
    let id: String
    let senderFbid: String?
    let timestampMs: String?
    /// Such as `TEXT`, `IMAGES`, `MESSAGE_INLINE_SHARE`, `MONTAGE_SHARE_XMA` or `REACTION_LOG_XMAT`.
    let contentType: String?
    /// The text, or empty for most attachments.
    let textBody: String?
    /// A one-line description, such as "Dylan sent an attachment." (inbox only).
    let igdSnippet: String?
    let content: InstagramDirectContent?
    let repliedToMessageId: String?
    var reactions: [Reaction]?
    let sender: Sender?

    var sentAt: Date? {
        instagramDirectDate(timestampMs)
    }

    var isMediaShare: Bool {
        contentType == "MESSAGE_INLINE_SHARE"
    }
}

struct InstagramDirectContent: Codable {
    struct TextFragment: Codable {
        let plaintext: String?
    }

    /// Images (`attachments`), videos (`videos`) and mixed albums (`ordered_photo_video_attachments`).
    struct Attachment: Codable {
        let typename: String?
        let attachmentCdnUrl: String?
        let previewCdnUrl: String?
        let previewWidth: Double?
        let previewHeight: Double?

        var isVideo: Bool {
            typename?.contains("Video") == true
        }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case attachmentCdnUrl
            case previewCdnUrl
            case previewWidth
            case previewHeight
        }
    }

    /// A shared post, reel or story, or a placeholder for one that expired.
    struct XMA: Codable {
        struct PreviewImage: Codable {
            let url: String?
            let width: Double?
            let height: Double?
            let previewImageDecorationType: String?
        }

        let typename: String?
        let headerTitleText: String?
        let titleText: String?
        let captionBodyText: String?
        let eyebrowText: String?
        let targetUrl: String?
        let previewImage: PreviewImage?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case headerTitleText
            case titleText
            case captionBodyText
            case eyebrowText
            case targetUrl
            case previewImage
        }
    }

    let typename: String?
    let textBody: String?
    /// Text sent with a share, such as a story reply.
    let xmaTextBody: String?
    let xma: XMA?
    let attachments: [Attachment]?
    let videos: [Attachment]?
    let orderedPhotoVideoAttachments: [Attachment]?
    /// Admin messages, such as "Reacted 😂 to your message".
    let textFragments: [TextFragment]?

    var media: [Attachment] {
        (orderedPhotoVideoAttachments ?? []) + (attachments ?? []) + (videos ?? [])
    }

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case textBody
        case xmaTextBody
        case xma
        case attachments
        case videos
        case orderedPhotoVideoAttachments
        case textFragments
    }
}

struct InstagramDirectSentMessage: Decodable {
    let id: String
    let timestampMs: String?
}

func instagramDirectDate(_ milliseconds: String?) -> Date? {
    guard let milliseconds, let value = Double(milliseconds) else { return nil }
    return Date(timeIntervalSince1970: value / 1000)
}

@MainActor
extension InstagramClient {
    private static let inboxPage = "/direct/inbox/"

    /// The relay provider values the web inbox computes from gatekeepers at runtime.
    private static let directProvidedVariables: [String: Any] = [
        "__relay_internal__pv__IGDIsProfessionalAccountGKrelayprovider": false,
        "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider": true,
        "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider": 5,
        "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider": true,
        "__relay_internal__pv__IGDEnableOffMsysChatThemesQErelayprovider": false,
        "__relay_internal__pv__IGDInitialMessagePageCountrelayprovider": 20,
    ]

    private static func threadPage(_ threadFbid: String) -> String {
        "/direct/t/\(threadFbid)/"
    }

    /// The primary inbox's newest threads: 15, then 20 more per extra page.
    func directInbox(pages: Int = 1) async throws -> [InstagramDirectThread] {
        let credentials = try directCredentials()
        let deviceID = try await resolveDirectDeviceID(credentials: credentials)
        var variables = Self.directProvidedVariables
        variables["device_id_for_iris_subscription"] = deviceID
        guard let mailbox = try await directGraphQL(
            InstagramDirectMailbox.self,
            credentials: credentials,
            operation: "PolarisDirectInboxMobileQuery",
            pagePath: Self.inboxPage,
            rootField: "get_slide_mailbox_for_iris_subscription",
            variables: variables,
        ) else {
            throw SourceError.serviceError("Instagram Direct returned no inbox.")
        }
        var threads = mailbox.threadsByFolder.threads
        var pageInfo = mailbox.threadsByFolder.pageInfo
        for _ in 1 ..< max(pages, 1) {
            guard pageInfo.hasNextPage == true, let cursor = pageInfo.endCursor else { break }
            var pageVariables = Self.directProvidedVariables
            pageVariables["id"] = mailbox.id
            pageVariables["count"] = 20
            pageVariables["cursor"] = cursor
            pageVariables["folder"] = "INBOX"
            pageVariables["newer_than_timestamp_ms"] = NSNull()
            guard let page = try await directGraphQL(
                InstagramDirectMailbox.self,
                credentials: credentials,
                operation: "IGDThreadListOffMsysPaginationQuery",
                pagePath: Self.inboxPage,
                rootField: "fetch__SlideMailbox",
                variables: pageVariables,
            ) else { break }
            threads += page.threadsByFolder.threads
            pageInfo = page.threadsByFolder.pageInfo
        }
        return threads
    }

    /// One thread with its newest 20 messages.
    func directThread(threadFbid: String) async throws -> InstagramDirectThread {
        let credentials = try directCredentials()
        var variables = Self.directProvidedVariables
        variables["thread_fbid"] = threadFbid
        variables["min_uq_seq_id"] = NSNull()
        struct SlideThread: Decodable {
            let asIgDirectThread: InstagramDirectThread?
        }
        guard let thread = try await directGraphQL(
            SlideThread.self,
            credentials: credentials,
            operation: "IGDThreadDetailQuery",
            pagePath: Self.threadPage(threadFbid),
            rootField: "get_slide_thread_nullable",
            variables: variables,
        )?.asIgDirectThread else {
            throw SourceError.serviceError("Instagram Direct thread not found.")
        }
        return thread
    }

    /// The 20 messages before `cursor`, a previous page's `slide_messages.page_info.end_cursor`.
    func directOlderMessages(threadFbid: String, cursor: String) async throws -> InstagramDirectMessageConnection {
        let credentials = try directCredentials()
        var variables = Self.directProvidedVariables
        variables["id"] = threadFbid
        variables["after"] = cursor
        variables["first"] = 20
        for key in ["before", "last", "newer_than_message_id", "older_than_message_id"] {
            variables[key] = NSNull()
        }
        struct SlideThread: Decodable {
            struct Thread: Decodable {
                let slideMessages: InstagramDirectMessageConnection
            }

            let asIgDirectThread: Thread?
        }
        guard let messages = try await directGraphQL(
            SlideThread.self,
            credentials: credentials,
            operation: "IGDMessageListOffMsysQuery",
            pagePath: Self.threadPage(threadFbid),
            rootField: "fetch__SlideThread",
            variables: variables,
        )?.asIgDirectThread?.slideMessages else {
            throw SourceError.serviceError("Instagram Direct thread not found.")
        }
        return messages
    }

    /// Moves the viewer's read receipt to `messageId`. `threadId` is the thread's legacy id.
    func markDirectRead(threadFbid: String, threadId: String, messageId: String) async throws {
        let credentials = try directCredentials()
        struct Receipt: Decodable {
            let watermarkTimestampMs: String?
        }
        let receipt = try await directGraphQL(
            Receipt.self,
            credentials: credentials,
            operation: "useIGDMarkThreadAsReadMutation",
            pagePath: Self.threadPage(threadFbid),
            rootField: "xig_direct_item_seen_mutation_with_slide_messaging_response",
            variables: [
                "data": ["item_id": "", "message_id": messageId],
                "metadata": ["ig_thread_igid": threadId],
            ],
        )
        guard receipt != nil else {
            throw SourceError.serviceError("Instagram didn't mark the chat read.")
        }
    }

    /// Sets the viewer's reaction on a message, replacing any other (one per person), or deletes it. Deleting
    /// needs the emoji as Instagram stored it, which drops the variation selector (❤️ is stored as ❤). Returns
    /// the message's reactions afterwards.
    func setDirectReaction(threadFbid: String, messageId: String, emoji: String, remove: Bool) async throws -> [InstagramDirectMessage.Reaction] {
        let credentials = try directCredentials()
        struct Response: Decodable {
            struct SlideMessage: Decodable {
                let reactions: [InstagramDirectMessage.Reaction]?
            }

            let slideMessage: SlideMessage?
        }
        guard let response = try await directGraphQL(
            Response.self,
            credentials: credentials,
            operation: "IGDirectReactionSendMutation",
            pagePath: Self.threadPage(threadFbid),
            rootField: "xig_direct_reaction_send_with_slide_messaging_response",
            variables: [
                "input": [
                    "emoji": emoji,
                    "item_id": "",
                    "message_id": messageId,
                    "reaction_status": remove ? "deleted" : "created",
                    "thread_id": threadFbid,
                ],
            ],
        ) else {
            throw SourceError.serviceError("Instagram didn't save the reaction.")
        }
        return response.slideMessage?.reactions ?? []
    }

    func sendDirectText(threadFbid: String, text: String, replyToMessageId: String?) async throws -> InstagramDirectSentMessage {
        let credentials = try directCredentials()
        let variables: [String: Any] = [
            "commands": NSNull(),
            "forwarded_from_thread_id": NSNull(),
            "ig_thread_igid": threadFbid,
            "is_forwarded_from_own_message": NSNull(),
            "mentioned_user_ids": NSNull(),
            "mentions": NSNull(),
            "offline_threading_id": Self.offlineThreadingID(),
            "recipient_igids": NSNull(),
            "replied_to_item_id": NSNull(),
            "reply_to_message_id": replyToMessageId ?? NSNull(),
            "send_attribution": NSNull(),
            "text": ["sensitive_string_value": text],
        ]
        guard let sent = try await directGraphQL(
            InstagramDirectSentMessage.self,
            credentials: credentials,
            operation: "IGDirectTextSendMutation",
            pagePath: Self.threadPage(threadFbid),
            rootField: "xig_direct_text_send_with_slide_messaging_response",
            variables: variables,
        ) else {
            throw SourceError.serviceError("Instagram didn't send the message.")
        }
        return sent
    }

    /// Messenger's client message id: milliseconds since the epoch shifted left 22 bits, plus 22 random bits.
    static func offlineThreadingID(now: Date = Date()) -> String {
        let milliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        return String((milliseconds << 22) | UInt64.random(in: 0 ..< (1 << 22)))
    }

    private func directCredentials() throws -> InstagramCredentials {
        guard let credentials = try credentialStore.loadInstagramCredentials() else {
            throw SourceError.notConfigured
        }
        return credentials
    }

    /// The operation's root field, or `nil` when it is null.
    private func directGraphQL<Root: Decodable>(
        _: Root.Type,
        credentials: InstagramCredentials,
        operation: String,
        pagePath: String,
        rootField: String,
        variables: [String: Any],
    ) async throws -> Root? {
        let docID = try await directDocID(credentials: credentials, operation: operation, pagePath: pagePath)
        let data = try await graphqlPost(credentials: credentials, docID: docID, variables: variables, friendlyName: operation, rootFieldName: rootField)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.invalidResponse
        }
        if let error = (envelope["errors"] as? [[String: Any]])?.first {
            throw SourceError.serviceError(error["message"] as? String ?? "Instagram Direct request failed.")
        }
        guard let root = (envelope["data"] as? [String: Any])?[rootField], !(root is NSNull) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Root.self, from: JSONSerialization.data(withJSONObject: root))
    }

    /// Direct's doc IDs are only in the scripts of a real thread page; the inbox page has the inbox and thread
    /// detail queries. Each page is loaded at most once per operation that is missing.
    private func directDocID(credentials: InstagramCredentials, operation: String, pagePath: String) async throws -> String {
        if let docID = docIds[operation] { return docID }
        try await loadDirectPage(credentials: credentials, path: pagePath)
        if let docID = docIds[operation] { return docID }
        throw SourceError.serviceError("Could not discover Instagram operation \(operation).")
    }

    /// The MQTT web device id the inbox query is scoped to, from any Direct page.
    private func resolveDirectDeviceID(credentials: InstagramCredentials) async throws -> String {
        if let directDeviceID { return directDeviceID }
        try await loadDirectPage(credentials: credentials, path: Self.inboxPage)
        guard let directDeviceID else {
            throw SourceError.serviceError("Instagram Direct page had no device id.")
        }
        return directDeviceID
    }

    private func loadDirectPage(credentials: InstagramCredentials, path: String) async throws {
        if let inFlight = directPageLoads[path] {
            return try await inFlight.value
        }
        let task = Task {
            try await ensureBootstrapped(credentials: credentials)
            let html = try await webTextRequest(credentials: credentials, method: "GET", url: URL(string: Self.baseURL + path)!, headers: basePageHeaders(credentials: credentials))
            var discovered = parseDocIds(source: html)
            for scriptURL in scriptURLs(html: html) {
                guard let source = try? await webTextRequest(credentials: credentials, method: "GET", url: scriptURL, headers: baseAssetHeaders(credentials: credentials)) else { continue }
                discovered.merge(parseDocIds(source: source)) { _, new in new }
            }
            docIds.merge(discovered) { _, new in new }
            if let deviceID = firstMatch(html, pattern: #""IGDMqttWebDeviceID",\[\],\{"clientId":"([^"]+)""#) {
                directDeviceID = deviceID
            }
        }
        directPageLoads[path] = task
        defer { directPageLoads[path] = nil }
        try await task.value
    }
}

@MainActor
extension InstagramClient: ChatListProvider {
    public nonisolated var network: SocialNetwork {
        .instagram
    }

    /// The newest 35 inbox threads. Unread counts only cover each thread's 5 newest messages.
    public func chatList() async throws -> ChatListPage {
        try await ChatListPage(chats: directInbox(pages: 2).map(Self.chatSummary), archived: [])
    }

    static func chatSummary(_ thread: InstagramDirectThread) -> ChatSummary {
        let isGroup = thread.isGroup == true
        let partner = isGroup ? nil : thread.others.first
        var preview: String?
        if let latest = thread.messages.first {
            let body = InstagramDirectMessageParser.preview(of: latest).replacingOccurrences(of: "\n", with: " ")
            if latest.senderFbid == thread.viewerFbid {
                preview = "You: \(body)"
            } else if isGroup, let sender = thread.others.first(where: { $0.interopMessagingUserFbid == latest.senderFbid }) {
                preview = "\(sender.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? sender.username ?? "Someone"): \(body)"
            } else {
                preview = body
            }
        }
        let unread = thread.unreadMessages.count
        return ChatSummary(
            id: "instagram:direct:\(thread.threadFbid)",
            network: .instagram,
            title: thread.threadTitle ?? partner?.fullName ?? partner?.username ?? "Chat",
            avatarURL: (isGroup ? thread.threadImageUrl : partner?.profilePicUrl).flatMap(URL.init),
            preview: preview,
            timestamp: thread.messages.first?.sentAt,
            unreadCount: unread == 0 && thread.markedAsUnread == true ? 1 : unread,
            destination: .instagram(threadFbid: thread.threadFbid),
            namesSenderInPreview: isGroup,
            // A group's title may be a custom name or its members' names; the thread doesn't say which.
            titleNamesPeople: true,
        )
    }
}
