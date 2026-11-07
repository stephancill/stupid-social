import Foundation
@testable import StupidSocialCore
import XCTest

/// Discord gateway and REST payloads shaped like those `scripts/discord-web-client.py` recorded (synthetic ids and
/// text), mapped without the network or the UI.
@MainActor
final class DiscordChatTests: XCTestCase {
    private let me = "100000000000000001"
    private let friend = "100000000000000002"
    private let guildId = "200000000000000001"
    private let general = "300000000000000001"
    private let secret = "300000000000000002"
    private let dm = "300000000000000003"
    private let modRole = "400000000000000001"
    /// Snowflakes for 2026: (ms since 2015) << 22.
    private func snowflake(_ offset: UInt64) -> String {
        String((UInt64(1_793_000_000_000) - DiscordSnowflake.epoch + offset) << 22)
    }

    private func user(_ id: String, _ name: String, global: String? = nil) -> String {
        """
        {"id": "\(id)", "username": "\(name)", "global_name": \(global.map { "\"\($0)\"" } ?? "null"), "avatar": null, "discriminator": "0"}
        """
    }

    private func readyJSON(muted: Bool = false, readId: String? = nil, mentionCount: Int = 0, threads: String = "[]") -> String {
        """
        {"v": 9, "session_id": "s", "resume_gateway_url": "wss://gateway-us-east1-d.discord.gg",
         "user": \(user(me, "me", global: "Me")),
         "guilds": [{
           "id": "\(guildId)", "name": "Guild", "icon": null, "owner_id": "\(friend)",
           "roles": [
             {"id": "\(guildId)", "name": "@everyone", "permissions": "\(DiscordPermissions.viewChannel | DiscordPermissions.sendMessages | DiscordPermissions.addReactions | DiscordPermissions.attachFiles)"},
             {"id": "\(modRole)", "name": "Mods", "permissions": "0"}
           ],
           "members": [{"user": \(user(me, "me")), "roles": [], "nick": null}, {"user": \(user(friend, "friend")), "roles": ["\(modRole)"], "nick": "Pal"}],
           "emojis": [{"id": "500000000000000001", "name": "wave", "animated": false}],
           "stickers": [{"id": "600000000000000001", "name": "Hi", "tags": "👋", "format_type": 1, "guild_id": "\(guildId)", "available": true}],
           "threads": \(threads),
           "channels": [
             {"id": "\(general)", "type": 0, "name": "general", "position": 0, "parent_id": null, "last_message_id": "\(snowflake(5000))", "permission_overwrites": []},
             {"id": "\(secret)", "type": 0, "name": "mods", "position": 1, "last_message_id": "\(snowflake(4000))",
              "permission_overwrites": [{"id": "\(guildId)", "type": 0, "allow": "0", "deny": "\(DiscordPermissions.viewChannel)"},
                                        {"id": "\(modRole)", "type": 0, "allow": "\(DiscordPermissions.viewChannel)", "deny": "0"}]},
             {"id": "300000000000000009", "type": 2, "name": "Voice", "position": 2, "permission_overwrites": []}
           ]
         }],
         "private_channels": [
           {"id": "\(dm)", "type": 1, "last_message_id": "\(snowflake(6000))", "recipients": [\(user(friend, "friend"))], "is_message_request": false, "is_spam": false, "flags": 0},
           {"id": "300000000000000004", "type": 1, "last_message_id": "\(snowflake(7000))", "recipients": [\(user("100000000000000003", "spammer"))], "is_message_request": true, "is_spam": false, "flags": 0}
         ],
         "read_state": [
           {"id": "\(general)", "last_message_id": \(readId.map { "\"\($0)\"" } ?? "\"\(snowflake(5000))\""), "mention_count": \(mentionCount), "flags": 0, "last_pin_timestamp": "1970-01-01T00:00:00+00:00"},
           {"id": "\(dm)", "last_message_id": "\(snowflake(5500))", "mention_count": 1, "flags": 0, "last_pin_timestamp": "1970-01-01T00:00:00+00:00"}
         ],
         "user_guild_settings": [{"guild_id": "\(guildId)", "muted": \(muted), "channel_overrides": [], "version": 1}],
         "private_channels_version": "0", "experiments": [], "relationships": []}
        """
    }

    private func message(_ id: String, channel: String, author: String, authorName: String, content: String, type: Int = 0, attachments: String = "[]", extra: String = "") -> String {
        """
        {"id": "\(id)", "channel_id": "\(channel)", "type": \(type), "content": "\(content)", "author": \(user(author, authorName)),
         "timestamp": "2026-11-07T10:00:00.000000+00:00", "edited_timestamp": null, "attachments": \(attachments), "embeds": [],
         "mentions": [], "mention_roles": [], "pinned": false, "mention_everyone": false, "tts": false, "flags": 0\(extra)}
        """
    }

    private func gateway(_ ready: String, session: URLSession = .shared) throws -> DiscordGateway {
        let store = KeychainCredentialStore(service: "discord-chat-tests", prefersSynchronizable: false, allowsInsecureFallback: true).scoped(to: "discord-test")
        _ = try store.saveDiscordCredentials(DiscordCredentials(token: "test-token"))
        let gateway = DiscordGateway(client: DiscordClient(credentialStore: store, session: session))
        try gateway.apply(ready: JSONDecoder.discord.decode(DiscordReady.self, from: Data(ready.utf8)))
        return gateway
    }

    private func dispatch(_ gateway: DiscordGateway, _ name: String, _ data: String) {
        gateway.dispatch(name, data: Data(#"{"op": 0, "t": "\#(name)", "s": 1, "d": \#(data)}"#.utf8))
    }

    // MARK: Snowflakes and permissions

    func testSnowflakeDate() {
        XCTAssertEqual(DiscordSnowflake.date("175928847299117063")?.timeIntervalSince1970 ?? 0, 1_462_015_105.796, accuracy: 0.001)
        XCTAssertTrue(DiscordSnowflake.isAfter("10", "9"), "numeric, not string, order")
        XCTAssertTrue(DiscordSnowflake.isAfter("1", nil))
    }

    func testListsChannelsTheUserCanSee() throws {
        let gateway = try gateway(readyJSON())
        let list = DiscordChatList(gateway: gateway, accountId: "discord-a", chatList: nil)
        let ids = Set(list.listedChannels().map(\.id))
        XCTAssertEqual(ids, [general, dm], "the mods-only channel, the voice channel and the message request aren't listed")
    }

    func testAdministratorAndOwnerSeeEverything() throws {
        let guild = try XCTUnwrap(gateway(readyJSON()).guild(id: guildId))
        let hidden = try XCTUnwrap(guild.channels.first { $0.id == secret })
        XCTAssertEqual(DiscordPermissions.of(userId: friend, in: guild, channel: hidden), .max, "the owner")
        XCTAssertEqual(DiscordPermissions.of(userId: me, in: guild, channel: hidden) & DiscordPermissions.viewChannel, 0)
    }

    // MARK: Chats list

    func testRowsLikeApronRooms() throws {
        let gateway = try gateway(readyJSON(muted: true, readId: snowflake(1000), mentionCount: 2))
        let list = DiscordChatList(gateway: gateway, accountId: "discord-a", chatList: nil)
        let channel = try XCTUnwrap(gateway.channel(id: general))
        let row = list.summary(channel)
        XCTAssertEqual(row.title, "general")
        XCTAssertEqual(row.titlePrefix, "Guild", "the guild's name before the channel's, as Apron's server before its room")
        XCTAssertEqual(row.destination, .discord(channelId: general))
        XCTAssertTrue(row.isMuted)
        XCTAssertEqual(row.unreadCount, 2, "without a page, the mention count")
        XCTAssertTrue(row.namesSenderInPreview)
        XCTAssertEqual(row.timestamp, DiscordSnowflake.date(snowflake(5000)))

        let dmRow = try list.summary(XCTUnwrap(gateway.channel(id: dm)))
        XCTAssertEqual(dmRow.title, "friend")
        XCTAssertNil(dmRow.titlePrefix)
        XCTAssertFalse(dmRow.namesSenderInPreview)
        XCTAssertTrue(dmRow.titleNamesPeople)
        XCTAssertEqual(dmRow.avatarColorKey, friend)
    }

    func testLiveMessageUpdatesRowAndReadState() throws {
        let gateway = try gateway(readyJSON())
        let list = DiscordChatList(gateway: gateway, accountId: "discord-a", chatList: nil)
        let id = snowflake(9000)
        dispatch(gateway, "MESSAGE_CREATE", message(id, channel: general, author: friend, authorName: "friend", content: "hey <@\(me)>"))
        let row = try list.summary(XCTUnwrap(gateway.channel(id: general)))
        XCTAssertEqual(row.preview, "friend: hey @Me")
        XCTAssertEqual(row.unreadCount, 1)

        dispatch(gateway, "MESSAGE_ACK", #"{"channel_id": "\#(general)", "message_id": "\#(id)", "version": 3}"#)
        XCTAssertEqual(try list.summary(XCTUnwrap(gateway.channel(id: general))).unreadCount, 0)

        let own = snowflake(9500)
        dispatch(gateway, "MESSAGE_CREATE", message(own, channel: general, author: me, authorName: "me", content: "hi"))
        let ownRow = try list.summary(XCTUnwrap(gateway.channel(id: general)))
        XCTAssertEqual(ownRow.preview, "You: hi")
        XCTAssertEqual(ownRow.unreadCount, 0, "sending reads the channel")
    }

    // MARK: Text

    func testTextTokens() {
        let (text, emojis) = DiscordText.display(
            "hi <@!\(friend)> in <#\(general)> <@&\(modRole)> <:wave:500000000000000001> <a:spin:500000000000000002>",
            context: DiscordText.Context(channelNames: [general: "general"], roleNames: [modRole: "Mods"]),
        )
        XCTAssertEqual(text, "hi @\(friend) in #general @Mods :500000000000000001: :500000000000000002:")
        XCTAssertEqual(Set(emojis.compactMap(\.name)), ["spin", "wave"])
        XCTAssertEqual(emojis.first { $0.name == "spin" }?.animated, true)
        XCTAssertEqual(DiscordText.outgoing("ping @\(friend)!"), "ping <@\(friend)>!")
        XCTAssertEqual(DiscordText.outgoing("call 0123456789"), "call 0123456789", "only @-prefixed ids")
    }

    // MARK: Adapter

    func testAdapterMapsLiveMessages() async throws {
        let gateway = try gateway(readyJSON(readId: snowflake(1000)))
        let adapter = DiscordChatAdapter(gateway: gateway, channelId: general, title: "general")
        await adapter.startFollowing()
        XCTAssertEqual(adapter.info.subtitle, "Guild")
        XCTAssertTrue(adapter.info.showsSenderNames)
        XCTAssertFalse(adapter.isReadOnly)

        let first = snowflake(2000)
        let attachment = #"[{"id": "1", "filename": "a.png", "size": 10, "url": "https://cdn.discordapp.com/a.png", "proxy_url": "https://media.discordapp.net/a.png", "width": 200, "height": 100, "content_type": "image/png"}]"#
        let reactions = #", "reactions": [{"emoji": {"id": null, "name": "👍"}, "count": 2, "me": true}, {"emoji": {"id": "500000000000000001", "name": "wave"}, "count": 1, "me": false}]"#
        dispatch(gateway, "MESSAGE_CREATE", message(first, channel: general, author: friend, authorName: "friend", content: "", attachments: attachment, extra: reactions))
        let reply = snowflake(3000)
        let reference = #", "message_reference": {"channel_id": "\#(general)", "message_id": "\#(first)"}, "referenced_message": null"#
        dispatch(gateway, "MESSAGE_CREATE", message(reply, channel: general, author: me, authorName: "me", content: "**nice** <:wave:500000000000000001>", type: 19, extra: reference))
        dispatch(gateway, "MESSAGE_CREATE", message(snowflake(3500), channel: general, author: friend, authorName: "friend", content: "", type: 7))
        dispatch(gateway, "MESSAGE_CREATE", message(snowflake(4000), channel: "300000000000000099", author: friend, authorName: "friend", content: "elsewhere"))

        XCTAssertEqual(adapter.messages.map(\.id), [first, reply, snowflake(3500)])
        let photo = adapter.messages[0]
        XCTAssertEqual(photo.sender.name, "Pal", "the guild nickname")
        XCTAssertNil(photo.text)
        XCTAssertEqual(photo.embeds, try [.image(url: XCTUnwrap(URL(string: "https://cdn.discordapp.com/a.png")), aspectRatio: 2, alt: "a.png", link: nil, opensViewer: true)])
        XCTAssertEqual(adapter.reactions[first], [ChatReaction(emoji: "👍", count: 2, includesYou: true), ChatReaction(emoji: ":500000000000000001:", count: 1, includesYou: false)])
        XCTAssertEqual(adapter.yourEmojis(on: first), ["👍"])
        XCTAssertNotNil(adapter.customEmojis[":500000000000000001:"])

        let sent = adapter.messages[1]
        XCTAssertTrue(sent.isOwn)
        XCTAssertTrue(sent.isMarkdown)
        XCTAssertEqual(sent.text, "**nice** :500000000000000001:")
        XCTAssertEqual(sent.replyToId, first)
        XCTAssertEqual(adapter.editableText(of: sent), "**nice** :500000000000000001:")
        XCTAssertNil(adapter.editableText(of: photo), "someone else's")
        XCTAssertTrue(adapter.messages[2].sender.isSystem, "a join is a system message")

        XCTAssertTrue(adapter.isAfterReadPosition(photo))
        XCTAssertNotNil(adapter.markRead(upTo: photo))
        XCTAssertFalse(adapter.isAfterReadPosition(photo))
        XCTAssertNil(adapter.markRead(upTo: photo), "already read")

        dispatch(gateway, "MESSAGE_UPDATE", #"{"id": "\#(reply)", "channel_id": "\#(general)", "content": "edited", "edited_timestamp": "2026-11-07T10:01:00+00:00"}"#)
        XCTAssertEqual(adapter.messages[1].text, "edited")
        XCTAssertTrue(adapter.messages[1].isEdited)
        dispatch(gateway, "MESSAGE_DELETE", #"{"id": "\#(reply)", "channel_id": "\#(general)"}"#)
        XCTAssertFalse(adapter.messages.contains { $0.id == reply })

        dispatch(gateway, "TYPING_START", #"{"channel_id": "\#(general)", "user_id": "\#(friend)", "timestamp": 1}"#)
        XCTAssertEqual(adapter.typingNames, ["Pal"])
        adapter.stopFollowing()
    }

    func testSnapshotRoundTrip() async throws {
        let gateway = try gateway(readyJSON())
        let adapter = DiscordChatAdapter(gateway: gateway, channelId: dm, title: "friend")
        await adapter.startFollowing()
        dispatch(gateway, "MESSAGE_CREATE", message(snowflake(6000), channel: dm, author: friend, authorName: "friend", content: "hello"))
        let data = try XCTUnwrap(adapter.snapshot())

        let restored = DiscordChatAdapter(gateway: gateway, channelId: dm, title: "friend")
        restored.restore(snapshot: data)
        XCTAssertEqual(restored.messages.map(\.text), ["hello"])
        XCTAssertFalse(restored.info.showsSenderNames, "a DM")
        XCTAssertEqual(restored.info.subtitle, "@friend")
    }

    // MARK: Threads and forums

    private func thread(_ id: String, type: Int = 11, name: String, joined: Bool, last: UInt64) -> String {
        """
        {"id": "\(id)", "type": \(type), "name": "\(name)", "parent_id": "\(general)", "guild_id": "\(guildId)", "last_message_id": "\(snowflake(last))",
         "thread_metadata": {"archived": false, "locked": false}\(joined ? ", \"member\": {\"user_id\": \"\(me)\"}" : "")}
        """
    }

    func testJoinedThreadsAreListedUnderTheirChannel() throws {
        let joined = "700000000000000001"
        let other = "700000000000000002"
        let hidden = "700000000000000003"
        let threads = "[\(thread(joined, name: "plans", joined: true, last: 8000)), \(thread(other, name: "chatter", joined: false, last: 8100)), \(thread(hidden, type: 12, name: "secret", joined: false, last: 8200))]"
        let gateway = try gateway(readyJSON(threads: threads))
        let list = DiscordChatList(gateway: gateway, accountId: "discord-a", chatList: nil)
        XCTAssertEqual(Set(list.listedChannels().map(\.id)), [general, dm, joined], "only threads the user joined")
        let row = try list.summary(XCTUnwrap(gateway.channel(id: joined)))
        XCTAssertEqual(row.title, "plans")
        XCTAssertEqual(row.titlePrefix, "Guild / general")
        XCTAssertEqual(row.unreadCount, 0, "a thread without a read state isn't unread")
        XCTAssertEqual(try gateway.permissions(in: XCTUnwrap(gateway.channel(id: hidden))), 0, "a private thread needs membership")

        dispatch(gateway, "THREAD_MEMBERS_UPDATE", #"{"id": "\#(other)", "guild_id": "\#(guildId)", "member_count": 2, "added_members": [{"user_id": "\#(me)", "id": "\#(other)"}]}"#)
        XCTAssertTrue(list.listedChannels().contains { $0.id == other }, "joining lists it")

        let adapter = DiscordChatAdapter(gateway: gateway, channelId: joined, title: "plans")
        XCTAssertEqual(adapter.info.subtitle, "Guild / #general")
    }

    func testThreadListSyncKeepsMembership() throws {
        let gateway = try gateway(readyJSON())
        let id = "700000000000000005"
        dispatch(gateway, "THREAD_LIST_SYNC", """
        {"guild_id": "\(guildId)", "threads": [\(thread(id, name: "synced", joined: false, last: 9000))], "members": [{"id": "\(id)", "user_id": "\(me)"}]}
        """)
        XCTAssertNotNil(gateway.channel(id: id)?.member)
        dispatch(gateway, "THREAD_UPDATE", thread(id, name: "renamed", joined: false, last: 9100))
        XCTAssertEqual(gateway.channel(id: id)?.title, "renamed")
        XCTAssertNotNil(gateway.channel(id: id)?.member, "an update without a member keeps the membership")
    }

    // MARK: Starting DMs

    func testNewDMResolvesBeforeItHasMessages() throws {
        let gateway = try gateway(readyJSON())
        let list = DiscordChatList(gateway: gateway, accountId: "discord-a", chatList: nil)
        let channel = try JSONDecoder.discord.decode(DiscordChannel.self, from: Data(#"{"id": "300000000000000077", "type": 1, "last_message_id": null, "recipients": [{"id": "100000000000000009", "username": "newfriend"}]}"#.utf8))
        gateway.remember(channel)
        XCTAssertFalse(list.listedChannels().contains { $0.id == channel.id }, "no messages yet")
        let row = try XCTUnwrap(list.chat(for: .discord(channelId: channel.id), in: []))
        XCTAssertEqual(row.title, "newfriend")
        XCTAssertNil(list.chat(for: .bluesky(convoId: "x"), in: []))
        XCTAssertEqual(DiscordProfileViewModel.dmRecipient(channelId: dm, gateway: gateway), friend)
        XCTAssertNil(DiscordProfileViewModel.dmRecipient(channelId: general, gateway: gateway))
    }

    // MARK: Stickers

    func testStickerFormats() {
        XCTAssertEqual(DiscordChatAdapter.sticker(id: "1", formatType: 1, alt: nil)?.url.absoluteString, "https://media.discordapp.net/stickers/1.png?size=320")
        XCTAssertEqual(DiscordChatAdapter.sticker(id: "1", formatType: 4, alt: nil)?.url.absoluteString, "https://media.discordapp.net/stickers/1.gif?size=320")
        let lottie = DiscordChatAdapter.sticker(id: "2", formatType: 3, alt: "Wave")
        XCTAssertEqual(lottie?.format, .lottie)
        XCTAssertEqual(lottie?.url.absoluteString, "https://discord.com/stickers/2.json")
        XCTAssertNil(DiscordChatAdapter.sticker(id: "3", formatType: 9, alt: nil))
    }

    func testPlainLottieJSONParses() throws {
        let json = #"{"v": "5.5.2", "fr": 60, "ip": 0, "op": 60, "w": 320, "h": 320, "layers": []}"#
        let animation = try LottieAnimation(json: Data(json.utf8))
        XCTAssertEqual(animation.frameCount, 60)
        XCTAssertThrowsError(try LottieAnimation(tgs: Data(json.utf8)), "not gzip, so the loader falls back to plain JSON")
    }

    // MARK: Sending files and stickers

    func testUploadThenSend() async throws {
        DiscordURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscordURLProtocol.self]
        let gateway = try gateway(readyJSON(), session: URLSession(configuration: configuration))
        let adapter = DiscordChatAdapter(gateway: gateway, channelId: general, title: "general")
        await adapter.startFollowing()
        let sentId = snowflake(9900)
        let general = general
        let sentJSON = message(sentId, channel: general, author: me, authorName: "me", content: "look")
        DiscordURLProtocol.handler = { request, body in
            switch (request.httpMethod ?? "", request.url?.host() ?? "", request.url?.path() ?? "") {
            case ("POST", "discord.com", "/api/v9/channels/\(general)/attachments"):
                return (200, #"{"attachments": [{"id": 0, "upload_url": "https://discord-attachments-uploads-prd.storage.googleapis.com/u/a.png?sig=1", "upload_filename": "u/a.png"}]}"#)
            case ("PUT", "discord-attachments-uploads-prd.storage.googleapis.com", _):
                XCTAssertEqual(body, Data("PNG".utf8))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the storage URL is signed; the token stays with Discord")
                return (200, "")
            case ("POST", "discord.com", "/api/v9/channels/\(general)/messages"):
                return (200, sentJSON)
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (404, "{}")
            }
        }
        let id = try await adapter.send(ChatOutgoing(text: "look", attachment: ChatAttachment(data: Data("PNG".utf8), mimeType: "image/png", filename: "a.png", isImage: true), replyToId: nil))
        XCTAssertEqual(id, sentId)
        XCTAssertEqual(DiscordURLProtocol.requests.map(\.method), ["POST", "PUT", "POST"])
        let reserve = try XCTUnwrap(JSONSerialization.jsonObject(with: DiscordURLProtocol.requests[0].body) as? [String: Any])
        XCTAssertEqual((reserve["files"] as? [[String: Any]])?.first?["file_size"] as? Int, 3)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: DiscordURLProtocol.requests[2].body) as? [String: Any])
        XCTAssertEqual(sent["content"] as? String, "look")
        XCTAssertEqual((sent["attachments"] as? [[String: Any]])?.first?["uploaded_filename"] as? String, "u/a.png")
        XCTAssertEqual(DiscordURLProtocol.requests[2].authorization, "test-token")
        XCTAssertTrue(adapter.messages.contains { $0.id == sentId })
        XCTAssertTrue(adapter.acceptsAttachments)

        DiscordURLProtocol.reset()
        let stickerJSON = message(snowflake(9950), channel: general, author: me, authorName: "me", content: "")
        DiscordURLProtocol.handler = { _, _ in (200, stickerJSON) }
        let sticker = try XCTUnwrap(DiscordChatAdapter.sticker(id: "600000000000000001", formatType: 1, alt: "Hi"))
        _ = try await adapter.send(sticker: sticker, replyToId: sentId)
        let stickerBody = try XCTUnwrap(JSONSerialization.jsonObject(with: DiscordURLProtocol.requests[0].body) as? [String: Any])
        XCTAssertEqual(stickerBody["sticker_ids"] as? [String], ["600000000000000001"])
        XCTAssertEqual((stickerBody["message_reference"] as? [String: Any])?["message_id"] as? String, sentId)
        adapter.stopFollowing()
    }
}

private final class DiscordURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let body: Data
        let authorization: String?
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (Int, String))?
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

    /// Bodies arrive as a stream, both for `data(for:)` and `upload(for:from:)`.
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
        do {
            let body = Self.body(of: request)
            Self.requests.append(Recorded(method: request.httpMethod ?? "", body: body, authorization: request.value(forHTTPHeaderField: "Authorization")))
            let handler = try XCTUnwrap(Self.handler)
            let (status, response) = try handler(request, body)
            let http = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
