import Foundation
@testable import StupidSocialCore
import XCTest

/// LinkedIn Voyager and messenger GraphQL payloads shaped like those `scripts/linkedin-web-client.py` recorded
/// (synthetic names, ids and text), mapped without the network or the UI.
@MainActor
final class LinkedInTests: XCTestCase {
    private let me = "urn:li:fsd_profile:ME000"
    private let friend = "urn:li:fsd_profile:FRIEND1"
    private let conversation = "urn:li:msg_conversation:(urn:li:fsd_profile:ME000,2-THREAD==)"

    private func messageUrn(_ n: Int) -> String {
        "urn:li:msg_message:(urn:li:fsd_profile:ME000,2-M\(n)==)"
    }

    private func participant(_ urn: String, first: String, last: String) -> String {
        """
        {"hostIdentityUrn": "\(urn)", "entityUrn": "urn:li:msg_messagingParticipant:\(urn)",
         "participantType": {"member": {"firstName": {"text": "\(first)", "attributes": []}, "lastName": {"text": "\(last)", "attributes": []},
           "profileUrl": "https://www.linkedin.com/in/\(first.lowercased())",
           "profilePicture": {"rootUrl": "https://media.licdn.com/dms/image/\(first)/", "artifacts": [
             {"width": 100, "height": 100, "fileIdentifyingUrlPathSegment": "100.jpg"},
             {"width": 400, "height": 400, "fileIdentifyingUrlPathSegment": "400.jpg"}]}},
           "organization": null, "custom": null, "agent": null}}
        """
    }

    private func message(_ n: Int, from sender: String, text: String, at ms: Int64, format: String = "DEFAULT", reactions: String = "[]", render: String = "[]") -> String {
        """
        {"entityUrn": "\(messageUrn(n))", "deliveredAt": \(ms),
         "sender": {"hostIdentityUrn": "\(sender)", "entityUrn": "urn:li:msg_messagingParticipant:\(sender)"},
         "actor": \(sender == me ? participant(me, first: "Me", last: "Self") : participant(friend, first: "Pat", last: "Friend")),
         "body": {"text": "\(text)", "attributes": []}, "subject": null, "messageBodyRenderFormat": "\(format)",
         "reactionSummaries": \(reactions), "renderContent": \(render), "renderContentFallbackText": null}
        """
    }

    private func conversationJSON(unread: Int, lastReadAt: Int64, lastActivityAt: Int64, last: String, muted: Bool = false) -> String {
        """
        {"entityUrn": "\(conversation)", "conversationParticipants": [\(participant(me, first: "Me", last: "Self")), \(participant(friend, first: "Pat", last: "Friend"))],
         "unreadCount": \(unread), "lastActivityAt": \(lastActivityAt), "lastReadAt": \(lastReadAt), "read": \(unread == 0), "groupChat": false,
         "title": null, "notificationStatus": "\(muted ? "MUTE" : "ACTIVE")", "conversationUrl": "https://www.linkedin.com/messaging/thread/2-THREAD==/",
         "messages": {"elements": [\(last)]}}
        """
    }

    private let meJSON = """
    {"data": {"*miniProfile": "urn:li:fs_miniProfile:ME000"},
     "included": [{"dashEntityUrn": "urn:li:fsd_profile:ME000", "firstName": "Me", "lastName": "Self", "publicIdentifier": "me-self",
       "picture": {"rootUrl": "https://media.licdn.com/dms/image/me/", "artifacts": [{"width": 200, "height": 200, "fileIdentifyingUrlPathSegment": "200.jpg"}]}}]}
    """

    // MARK: Notifications

    func testNotificationCards() throws {
        let json = """
        {"data": {"*elements": ["urn:li:fsd_notificationCard:(JOB_CHANGE_PROP,urn:li:none)", "urn:li:fsd_notificationCard:(REACTION_TO_POST,urn:li:activity:1)"]},
         "included": [
          {"$type": "com.linkedin.voyager.dash.identity.profile.Profile", "entityUrn": "urn:li:fsd_profile:FRIEND1",
           "profilePicture": {"displayImageReference": {"vectorImage": {"rootUrl": "https://media.licdn.com/p/", "artifacts": [
             {"width": 100, "height": 100, "fileIdentifyingUrlPathSegment": "100.jpg"}, {"width": 200, "height": 200, "fileIdentifyingUrlPathSegment": "200.jpg"}]}}}},
          {"$type": "com.linkedin.voyager.dash.identity.notifications.Card", "entityUrn": "urn:li:fsd_notificationCard:(JOB_CHANGE_PROP,urn:li:none)",
           "headline": {"text": "Congratulate Pat Friend on a new position at Acme. View more network updates."},
           "read": false, "publishedAt": 1794170298472,
           "cardAction": {"actionTarget": "/mynetwork/catch-up/all?highlightedUrns=List(x)"},
           "headerImage": {"actionTarget": "/in/pat%2Dfriend", "accessibilityText": "View Pat Friend’s profile",
             "attributes": [{"detailData": {"*profilePicture": "urn:li:fsd_profile:FRIEND1"}}]}},
          {"$type": "com.linkedin.voyager.dash.identity.notifications.Card", "entityUrn": "urn:li:fsd_notificationCard:(REACTION_TO_POST,urn:li:activity:1)",
           "headline": {"text": "Pat Friend reacted to your post."}, "read": true, "publishedAt": 1794000000000,
           "contentPrimaryText": {"text": "My post"}, "cardAction": {"actionTarget": "https://www.linkedin.com/feed/update/urn:li:activity:1/"}}
         ]}
        """
        let cards = try LinkedInParser.notificationCards(from: Data(json.utf8))
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].kind, "JOB_CHANGE_PROP")
        XCTAssertEqual(cards[0].actorName, "Pat Friend")
        XCTAssertEqual(cards[0].imageURL?.absoluteString, "https://media.licdn.com/p/200.jpg")
        XCTAssertEqual(cards[0].url?.absoluteString, "https://www.linkedin.com/mynetwork/catch-up/all?highlightedUrns=List(x)")
        XCTAssertFalse(cards[0].read)

        let item = LinkedInNotificationSource.item(from: cards[0], accountId: "linkedin-1")
        XCTAssertEqual(item.text, "Congratulate Pat Friend on a new position at Acme.")
        XCTAssertEqual(item.actors.first?.username, "pat-friend")
        XCTAssertEqual(item.type, .unknown)
        XCTAssertEqual(item.timestamp, Date(timeIntervalSince1970: 1_794_170_298.472))

        let reaction = LinkedInNotificationSource.item(from: cards[1], accountId: "linkedin-1")
        XCTAssertEqual(reaction.type, .reaction)
        XCTAssertEqual(reaction.target?.text, "My post")
        XCTAssertEqual(reaction.target?.url?.absoluteString, "https://www.linkedin.com/feed/update/urn:li:activity:1/")
        XCTAssertNil(reaction.actors.first?.displayName)
    }

    func testNotificationTypesAndNames() {
        XCTAssertEqual(LinkedInNotificationSource.type(of: "MENTION_IN_COMMENT"), .mention)
        XCTAssertEqual(LinkedInNotificationSource.type(of: "COMMENT_ON_POST"), .reply)
        XCTAssertEqual(LinkedInNotificationSource.type(of: "INVITATION_ACCEPTED"), .follow)
        XCTAssertEqual(LinkedInParser.actorName(fromAccessibilityText: "View Sam Jones’ profile"), "Sam Jones")
        XCTAssertEqual(LinkedInParser.actorName(fromAccessibilityText: "View Ann's profile"), "Ann")
        XCTAssertNil(LinkedInParser.actorName(fromAccessibilityText: "Company logo"))
        XCTAssertEqual(LinkedInParser.kind(of: "urn:li:fsd_notificationCard:(EDUCATION_PROP,urn:li:uniqueSuffix:(urn:li:none,x))"), "EDUCATION_PROP")
        XCTAssertEqual(LinkedInClient.restli("urn:li:msg_conversation:(a,2-b==)"), "urn%3Ali%3Amsg_conversation%3A%28a%2C2-b%3D%3D%29")
    }

    func testMe() throws {
        let me = try LinkedInParser.me(from: Data(meJSON.utf8))
        XCTAssertEqual(me.profileUrn, self.me)
        XCTAssertEqual(me.name, "Me Self")
        XCTAssertEqual(me.publicIdentifier, "me-self")
        XCTAssertEqual(me.avatarURL?.absoluteString, "https://media.licdn.com/dms/image/me/200.jpg")
    }

    // MARK: Chats list

    func testChatSummary() throws {
        let json = conversationJSON(unread: 2, lastReadAt: 1000, lastActivityAt: 3000, last: message(3, from: me, text: "see you", at: 3000), muted: true)
        let parsed = try JSONDecoder().decode(LinkedInConversation.self, from: Data(json.utf8))
        let summary = LinkedInClient.chatSummary(parsed, viewerUrn: me)
        XCTAssertEqual(summary.title, "Pat Friend")
        XCTAssertEqual(summary.preview, "You: see you")
        XCTAssertEqual(summary.unreadCount, 2)
        XCTAssertTrue(summary.isMuted)
        XCTAssertTrue(summary.titleNamesPeople)
        XCTAssertEqual(summary.avatarURL?.absoluteString, "https://media.licdn.com/dms/image/Pat/400.jpg")
        XCTAssertEqual(summary.destination, .linkedin(conversationUrn: conversation))
    }

    // MARK: Adapter

    private func stubbedClient() -> LinkedInClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedInURLProtocol.self]
        let store = KeychainCredentialStore(service: "linkedin-tests", prefersSynchronizable: false, allowsInsecureFallback: true).scoped(to: "linkedin-test-account")
        _ = try? store.saveLinkedInCredentials(LinkedInCredentials(liAt: "test-li-at", jsessionId: "\"ajax:123\""))
        return LinkedInClient(credentialStore: store, session: URLSession(configuration: configuration))
    }

    private func routes(conversation conversationBody: String, messages: [String]) -> (URLRequest, Data) -> (Int, String) {
        let meJSON = meJSON
        return { request, _ in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/voyager/api/me") { return (200, meJSON) }
            if url.contains("messengerConversations.fb3eab") {
                return (200, #"{"data": {"messengerConversationsById": "# + conversationBody + "}}")
            }
            if url.contains("messengerMessages.5846ee") {
                return (200, #"{"data": {"messengerMessagesBySyncToken": {"elements": ["# + messages.joined(separator: ",") + "]}}}")
            }
            if request.httpMethod == "POST" {
                if url.contains("action=createMessage") {
                    return (200, #"{"value": {"entityUrn": "urn:li:msg_message:(urn:li:fsd_profile:ME000,2-NEW==)", "deliveredAt": 9000}}"#)
                }
                return (204, "")
            }
            return (404, "{}")
        }
    }

    func testAdapterMapsMessagesAndMarksReadOnlyAtTheNewest() async throws {
        let quoted = message(1, from: me, text: "lunch?", at: 1000)
        let reply = message(4, from: friend, text: "sure", at: 4000, render: """
        [{"repliedMessageContent": {"messageBody": {"text": "older question", "attributes": []}, "originalMessage": {"entityUrn": "\(messageUrn(0))"},
          "originalSender": \(participant(me, first: "Me", last: "Self")), "originalSendAt": 500}}]
        """)
        let messages = [
            message(5, from: friend, text: "", at: 5000, render: #"[{"externalMedia": {"title": "wave", "media": {"url": "https://media.tenor.com/a.gif", "originalWidth": 200, "originalHeight": 100}}}]"#),
            reply,
            message(3, from: friend, text: "edited text", at: 3000, format: "EDITED", reactions: #"[{"emoji": "👍", "count": 2, "viewerReacted": true}]"#),
            message(2, from: me, text: "", at: 2000, format: "RECALLED"),
            quoted,
        ]
        LinkedInURLProtocol.reset()
        LinkedInURLProtocol.handler = routes(
            conversation: conversationJSON(unread: 2, lastReadAt: 3500, lastActivityAt: 5000, last: messages[0]),
            messages: messages,
        )
        let adapter = LinkedInChatAdapter(client: stubbedClient(), conversationUrn: conversation, title: "Pat Friend")
        try await adapter.loadNewest()

        XCTAssertEqual(adapter.messages.map(\.id), [1, 2, 3, 4, 5].map(messageUrn))
        XCTAssertTrue(adapter.messages[1].isDeleted)
        XCTAssertTrue(adapter.messages[2].isEdited)
        XCTAssertEqual(adapter.reactions[messageUrn(3)], [ChatReaction(emoji: "👍", count: 2, includesYou: true)])
        XCTAssertEqual(adapter.yourEmojis(on: messageUrn(3)), ["👍"])
        XCTAssertEqual(adapter.messages[3].replyToId, messageUrn(0))
        XCTAssertEqual(adapter.referencedMessages[messageUrn(0)]?.text, "older question")
        XCTAssertEqual(adapter.referencedMessages[messageUrn(0)]?.isOwn, true)
        guard case let .image(url, ratio, _, _, _) = adapter.messages[4].embeds.first else { return XCTFail("GIF") }
        XCTAssertEqual(url.absoluteString, "https://media.tenor.com/a.gif")
        XCTAssertEqual(ratio, 2)
        XCTAssertEqual(adapter.info.avatarUserId, friend)
        XCTAssertFalse(adapter.info.showsSenderNames)
        XCTAssertTrue(adapter.canDelete(adapter.messages[0]))
        XCTAssertFalse(adapter.canDelete(adapter.messages[2]))
        XCTAssertEqual(adapter.editableText(of: adapter.messages[0]), "lunch?")

        XCTAssertFalse(adapter.isAfterReadPosition(adapter.messages[2]))
        XCTAssertTrue(adapter.isAfterReadPosition(adapter.messages[3]))
        // Read state is per conversation: seeing the reply alone leaves the newer GIF unread on LinkedIn.
        XCTAssertNil(adapter.markRead(upTo: adapter.messages[3]))
        let send = try XCTUnwrap(adapter.markRead(upTo: adapter.messages[4]))
        LinkedInURLProtocol.requests = []
        try await send()
        let request = try XCTUnwrap(LinkedInURLProtocol.requests.first)
        XCTAssertEqual(request.url, "https://www.linkedin.com/voyager/api/voyagerMessagingDashMessengerConversations?ids=List(\(LinkedInClient.restli(conversation)))")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: [String: [String: [String: [String: Bool]]]]])
        XCTAssertEqual(body["entities"]?[conversation]?["patch"]?["$set"]?["read"], true)
        XCTAssertEqual(request.headers["csrf-token"], "ajax:123")
        XCTAssertEqual(request.headers["Cookie"], #"li_at=test-li-at; JSESSIONID="ajax:123""#)
        XCTAssertNil(adapter.markRead(upTo: adapter.messages[4]))
    }

    func testSendQuotesTheRepliedMessage() async throws {
        let messages = [message(1, from: friend, text: "question", at: 1000)]
        LinkedInURLProtocol.reset()
        LinkedInURLProtocol.handler = routes(conversation: conversationJSON(unread: 0, lastReadAt: 1000, lastActivityAt: 1000, last: messages[0]), messages: messages)
        let adapter = LinkedInChatAdapter(client: stubbedClient(), conversationUrn: conversation, title: "Pat Friend")
        try await adapter.loadNewest()
        LinkedInURLProtocol.requests = []

        let id = try await adapter.send(ChatOutgoing(text: "answer", attachment: nil, replyToId: messageUrn(1)))
        XCTAssertEqual(id, "urn:li:msg_message:(urn:li:fsd_profile:ME000,2-NEW==)")
        let create = try XCTUnwrap(LinkedInURLProtocol.requests.first { $0.url.contains("action=createMessage") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        XCTAssertEqual(body["mailboxUrn"] as? String, me)
        let sent = try XCTUnwrap(body["message"] as? [String: Any])
        XCTAssertEqual(sent["conversationUrn"] as? String, conversation)
        XCTAssertEqual((sent["body"] as? [String: Any])?["text"] as? String, "answer")
        let quote = try XCTUnwrap(((sent["renderContentUnions"] as? [[String: Any]])?.first?["repliedMessageContent"]) as? [String: Any])
        XCTAssertEqual(quote["originalMessageUrn"] as? String, messageUrn(1))
        XCTAssertEqual(quote["originalSenderUrn"] as? String, "urn:li:msg_messagingParticipant:\(friend)")
        XCTAssertEqual(quote["originalSendAt"] as? Int, 1000)
    }

    // MARK: Realtime

    /// A `DecoratedEvent` as the stream sends it: the topic and the decorated query's `result`.
    private func decorated(_ topic: String, field: String, result: String) -> Data {
        Data("""
        {"com.linkedin.realtimefrontend.DecoratedEvent": {"topic": "urn:li-realtime:\(topic):urn:li-realtime:myself",
          "payload": {"data": {"_type": "x", "\(field)": {"result": \(result)}}}}}
        """.utf8)
    }

    private func liveMessage(_ n: Int, from sender: String, text: String, at ms: Int64, format: String = "DEFAULT") -> String {
        let plain = message(n, from: sender, text: text, at: ms, format: format)
        return String(plain.dropLast()) + #", "conversation": {"entityUrn": "\#(conversation)"}}"#
    }

    func testRealtimeEventsParse() {
        XCTAssertNotNil(LinkedInLiveFeed.parse(Data(#"{"com.linkedin.realtimefrontend.ClientConnection": {"id": "c", "personalTopics": []}}"#.utf8)).flatMap {
            if case .opened = $0 { true } else { nil }
        })
        XCTAssertNil(LinkedInLiveFeed.parse(Data(#"{"com.linkedin.realtimefrontend.Heartbeat": {}}"#.utf8)))
        XCTAssertNil(LinkedInLiveFeed.parse(decorated("tabBadgeUpdateTopic", field: "value", result: "{}")))

        guard case let .event(.message(conversationUrn, parsedMessage)) = LinkedInLiveFeed.parse(decorated(
            "messagesTopic", field: "doDecorateMessageMessengerRealtimeDecoration", result: liveMessage(7, from: friend, text: "hi", at: 7000),
        )) else { return XCTFail("message") }
        XCTAssertEqual(conversationUrn, conversation)
        XCTAssertEqual(parsedMessage.entityUrn, messageUrn(7))

        guard case let .event(.reaction(reacted, summary)) = LinkedInLiveFeed.parse(decorated(
            "messageReactionSummariesTopic", field: "doDecorateRealtimeReactionSummaryMessengerRealtimeDecoration",
            result: #"{"reactionAdded": true, "actor": \#(participant(friend, first: "Pat", last: "Friend")), "message": {"entityUrn": "\#(messageUrn(7))"}, "reactionSummary": {"count": 2, "firstReactedAt": 1, "emoji": "👍", "viewerReacted": false}}"#,
        )) else { return XCTFail("reaction") }
        XCTAssertEqual(reacted, messageUrn(7))
        XCTAssertEqual(summary.count, 2)

        guard case let .event(.typing(typingIn, person)) = LinkedInLiveFeed.parse(decorated(
            "typingIndicatorsTopic", field: "doDecorateTypingIndicatorMessengerRealtimeDecoration",
            result: #"{"conversation": {"entityUrn": "\#(conversation)"}, "typingParticipant": \#(participant(friend, first: "Pat", last: "Friend"))}"#,
        )) else { return XCTFail("typing") }
        XCTAssertEqual(typingIn, conversation)
        XCTAssertEqual(person.name, "Pat Friend")

        guard case let .event(.conversation(updated)) = LinkedInLiveFeed.parse(decorated(
            "conversationsTopic", field: "doDecorateConversationMessengerRealtimeDecoration",
            result: conversationJSON(unread: 0, lastReadAt: 9000, lastActivityAt: 9000, last: message(1, from: me, text: "x", at: 1000)),
        )) else { return XCTFail("conversation") }
        XCTAssertEqual(updated.unreadCount, 0)
    }

    func testAdapterAppliesLiveEvents() async throws {
        let messages = [message(1, from: friend, text: "question", at: 1000)]
        LinkedInURLProtocol.reset()
        LinkedInURLProtocol.handler = routes(conversation: conversationJSON(unread: 0, lastReadAt: 1000, lastActivityAt: 1000, last: messages[0]), messages: messages)
        let adapter = LinkedInChatAdapter(client: stubbedClient(), conversationUrn: conversation, title: "Pat Friend")
        try await adapter.loadNewest()
        XCTAssertEqual(adapter.pollInterval, .seconds(10), "without a live feed it polls quickly")

        let participant = try JSONDecoder().decode(LinkedInParticipant.self, from: Data(participant(friend, first: "Pat", last: "Friend").utf8))
        adapter.handle(.typing(conversationUrn: conversation, participant))
        XCTAssertEqual(adapter.typingNames, ["Pat Friend"])
        adapter.handle(.typing(conversationUrn: "urn:li:msg_conversation:(other)", participant))
        XCTAssertEqual(adapter.typingNames, ["Pat Friend"])

        let live = try JSONDecoder().decode(LinkedInMessage.self, from: Data(message(2, from: friend, text: "answer", at: 2000).utf8))
        adapter.handle(.message(conversationUrn: conversation, live))
        XCTAssertEqual(adapter.messages.map(\.id), [messageUrn(1), messageUrn(2)])
        XCTAssertEqual(adapter.typingNames, [], "a message ends its sender's typing")
        XCTAssertTrue(adapter.isAfterReadPosition(adapter.messages[1]))

        adapter.handle(.reaction(messageUrn: messageUrn(2), LinkedInMessage.ReactionSummary(emoji: "🎉", count: 1, viewerReacted: false)))
        XCTAssertEqual(adapter.reactions[messageUrn(2)], [ChatReaction(emoji: "🎉", count: 1, includesYou: false)])
        adapter.handle(.reaction(messageUrn: messageUrn(2), LinkedInMessage.ReactionSummary(emoji: "🎉", count: 0, viewerReacted: false)))
        XCTAssertNil(adapter.reactions[messageUrn(2)])

        let recalled = try JSONDecoder().decode(LinkedInMessage.self, from: Data(message(2, from: friend, text: "", at: 2000, format: "RECALLED").utf8))
        adapter.handle(.message(conversationUrn: conversation, recalled))
        XCTAssertTrue(adapter.messages[1].isDeleted)
    }

    func testRedirectToLoginReadsAsSignedOut() async throws {
        LinkedInURLProtocol.reset()
        LinkedInURLProtocol.handler = { _, _ in (302, "") }
        do {
            _ = try await stubbedClient().me()
            XCTFail("expected notConfigured")
        } catch SourceError.notConfigured {}
    }

    func testLoginCookies() {
        let cookie = { (name: String, value: String) in
            HTTPCookie(properties: [.domain: ".www.linkedin.com", .path: "/", .name: name, .value: value])!
        }
        XCTAssertNil(LinkedInCredentials(cookies: [cookie("JSESSIONID", "\"ajax:1\"")]))
        let credentials = LinkedInCredentials(cookies: [cookie("JSESSIONID", "\"ajax:1\""), cookie("li_at", "AQ")])
        XCTAssertEqual(credentials, LinkedInCredentials(liAt: "AQ", jsessionId: "ajax:1"))
    }
}

private final class LinkedInURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: String
        let body: Data
        let headers: [String: String]
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, String))?
    nonisolated(unsafe) static var requests: [Recorded] = []

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.requests.append(Recorded(method: request.httpMethod ?? "", url: request.url?.absoluteString ?? "", body: body, headers: request.allHTTPHeaderFields ?? [:]))
        let (status, response) = Self.handler?(request, body) ?? (500, "")
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: status == 302 ? ["Location": "https://www.linkedin.com/login"] : nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
