import Foundation
@testable import NoFeedSocialCore
import NoFeedSocialPush
import XCTest

/// Vectors come from `scripts/telegram-client.py`, whose handshake and calls are checked against Telegram.
final class TelegramTests: XCTestCase {
    // MARK: Crypto

    func testIGEMatchesProbe() {
        let key = Data(hex: "a819408ce5010ca2e09ef59ac3d89f5ff8595d02b524e61bf8afa894a95d594f")
        let iv = Data(hex: "36710664d61b9295e5425ff00d65fbfa9071f3626c27b24f1189c014a6f531f5")
        let plain = Data(hex: "c198671ca5cdebca0e40db1f542340d4643a1fd2e1b99cc96451061d51fe0f3f42ef22f3a614ee7ee8066f001fd3a0d98569454f7915a771a3d08e0a8ea2ebf9")
        let cipher = Data(hex: "500a396e8cfd484d1b5d826095ed118bb080440757a73bb450f49e55bc0776acea7529eddd3789fd644604aacda2dbafbb5c5b88b5afae95a542e09eb79bd67b")
        XCTAssertEqual(TelegramCrypto.ige(plain, key: key, iv: iv, encrypt: true), cipher)
        XCTAssertEqual(TelegramCrypto.ige(cipher, key: key, iv: iv, encrypt: false), plain)
    }

    func testModularPowerMatchesProbe() {
        let base = BigUInt(bytes: Data(hex: "1d51f70f74c2566d8c1492f33d2b231f912e60c8935ed1309b0f223313865795c2d0da0251f952aa0a61276406d4a48ae94fd7eca84c0fddf94c89471790708cf80f514a2af03e24e1d757c6affdadd104f02e45aab583beac2c783810fa6e9833feb24d41c2abce69d6f0a2b032990c01a5f6fd9cfc469f39b1dbf526ec13be3422dac53a049e6f9983edca909d2ea76b9c8b416cc9e5649aff5f0485dd895d162b09dca80355fe965f1bdc82081dd43fb9d017ed92626f12f15ee05adaa9f0f20427b7be0001ad"))
        let exponent = BigUInt(bytes: Data(hex: "c6dfc9d7201815ff2c9437197c550a6c993793dad602ca67094cc648ef103e543c907cae300581207f0af176bb5ddcd0fafa9e0794090153df83d61b33efaed7c93b800807f4d75fe17e8b6fad23d54869e2f1735fe80a15b88a2e9400baa72244c69cd0a9c4b82ce3d68700227afd8e7d95bc2153556fe93e23104422d73e37b7953d9cbb49370a05b31a933e87b3cb09722ff2b2e1a9f802a7a876da776e221affa3cc88cc5f0e47344b7fc6affccff15f820dbe7ea2ca1db7ae482d04854b3b465a45e712273f8ef41dec434a80c1d5f76f3fd532b4ad4663dfb22d7052f694d409883b6453f459b655307810876baca4f86f7cb133755ca45e30d9585953"))
        let expected = Data(hex: "890d916b0703c36a14058a75e1d63c16d916d9bb486e27c4dfcb844119bef08224bd507efdca0a57cff26e6fb3a8cf143653ea01a687a4f90897f75535e72b4db96dcd5c4bbb73c37af9521a590fcc4f7466392fc847b00050ed39764096ffd008095f7a044ef789ce6f54c17449a6212637698e6ba97d168bb889d426fc88463bfef27e7ae6d5758a602ce9246a9e07a3749322c036aad9dce5525d2e6dd9735a9643eefc1de8c1a6347086e6698877d6fd7fe8be118e1eefd587c2fcfc86a8c5189c2938fc6ed52ce3e6f7d6915cdb7fd4a18fa15c59f88bb474ee24c033e021484431eed6034fb306733fd687e4a1d1de9ef10e485a856a52c1a3ce32132f")
        XCTAssertEqual(Montgomery(modulus: TelegramCrypto.dhPrime).power(base, exponent).bytes(length: 256), expected)
    }

    func testBigUIntArithmetic() {
        let a = BigUInt(bytes: Data(hex: "ffffffffffffffffffffffffffffffff"))
        let b = BigUInt(1)
        XCTAssertEqual((a + b).bytes(), Data(hex: "0100000000000000000000000000000000"))
        XCTAssertEqual(a + b - b, a)
        XCTAssertEqual((a * a).bytes(), Data(hex: "fffffffffffffffffffffffffffffffe00000000000000000000000000000001"))
        XCTAssertEqual(BigUInt(bytes: Data([0, 0, 5])).bytes(length: 4), Data([0, 0, 0, 5]))
    }

    func testSRPMatchesProbe() throws {
        let check = try TelegramCrypto.srp(
            password: "hunter2",
            salt1: Data(hex: "c4fa968a1f153361523d4a5b24ccbfc65747789d765326faddecfcc0ac5881c6d109b006e6d7f49e"),
            salt2: Data(hex: "47edb4d13b026f76a1310c950012810e"),
            g: 3,
            p: TelegramCrypto.dhPrime.bytes(length: 256),
            srpB: Data(hex: "780d5118a8d157b6f3f5c0e462d69ff82531799e7f323593e65e7af17cf55db6f29f3beb6827bd949ea89039aa6c4def1bdf945c62bb07e5bc3b2baca902e1e74c3270d386d5f57c5d7bbe3be45289bdda0b4ac2e3a5183cf62aaee42f2e1bd575511fa776717ba8ada3a291fd281f0578db8687acf92e94ae85e39a1824ce6b626520c960c0bd0a7aba307a9f1b841cf8d9f320697a450960826ebf34ece5f826b7f58fd068c2fa63340fa690a59804dfc6458479fbb8e5e48f703da657513744d9a87784a8101dc997b638c9259a6ab21383d8bdae3a0010ad7e3a53170cfe39a64fffdbc1dae17400e620bb754f799ec557ab813176c70f8ce6e9e5e03f"),
            secret: Data(hex: "97699b7cc0a0ed83b78b2002f0e57046ee561be6942bec256fe201abba552a9e5b11618c2e44027877d0cd0921ed166b9f176f50587fc91e7534dd2946db77d635224d0d3465d74e855f8d69a136e79c744ea35a675d3393360a327cbf6359a2e0d9ac7d3719d04d3d68bc463498b0889723c4e70c3549d43681dd8996b7177ffe2d033fef7942ed06d418992d35ca98feb53943d452f5994f96934d754e15cb19aa8a9a65d501367caed454cfe1c6fce944dc26df6b20f6fdbec80fd747312d9557483ec0b5979e7f07ff55f2bde181e6fa60473cb322bf429a444080660b845c5b5202833fb1b8653184f73b2b4e40ac7b7e6ebab843a157c9bf992755be42"),
        )
        XCTAssertEqual(check.a, Data(hex: "3df49fef9a6b9c1709558b7bcc34740ccbd62610aa2a9f8fe774a88bda9aa45a9ea07d509bdb98ddb0b4163256d5def389c5444d0dc755284e38646322f759640b636415660da9bb098b21ccd548c6b4eef44140c1897c40f728698e655b3f44915e1f48dff31b6c8fb43c4a537f4628a43e52ed6b42ab4ae420e44b1ddabf6055a18125c6ca47e049824e89f093026d65a72ebe2f04b81ead0f0bd3ef51727895903dff263c1b37843c50a222a9af973159a7918836a1a4300597bfa2c380bd41976d70a65a1df1c0974af7e194814239a3d7623947c17344efec1011da5656e4b1e80a4d024807a6fd6c08a885bd5aa0ea817f2b6fbf8326b77195b9111fa9"))
        XCTAssertEqual(check.m1, Data(hex: "1ad01014368e20a2ce6e7b12f9ddb0eba3a352b05d86b320ed9c6c9b1d26e553"))
    }

    /// Service messages name their people from the response's users, as Telegram words them.
    func testServiceMessagesNameTheirUsers() {
        func service(_ action: TLObject, from: Int64) -> String {
            TelegramClient.message(
                TLObject("messageService", ["id": .int(12), "date": .int(0), "from_id": .object(TLObject("peerUser", ["user_id": .long(from)])), "action": .object(action)]),
                selfId: 1,
                names: [1: "Stephan", 2: "Aho", 3: "Mat"],
            ).text
        }
        XCTAssertEqual(service(TLObject("messageActionChatJoinedByLink", ["inviter_id": .long(1)]), from: 2), "Aho joined the group via invite link")
        XCTAssertEqual(service(TLObject("messageActionChatAddUser", ["users": .vector([.long(2)])]), from: 2), "Aho joined the group")
        XCTAssertEqual(service(TLObject("messageActionChatAddUser", ["users": .vector([.long(2), .long(3)])]), from: 1), "You added Aho and Mat")
        XCTAssertEqual(service(TLObject("messageActionChatDeleteUser", ["user_id": .long(3)]), from: 3), "Mat left the group")
        XCTAssertEqual(service(TLObject("messageActionChatDeleteUser", ["user_id": .long(3)]), from: 2), "Aho removed Mat")
        XCTAssertEqual(service(TLObject("messageActionPinMessage"), from: 9), "Someone pinned a message")
    }

    func testFactorizesPQ() {
        let (p, q) = TelegramCrypto.factorize(0x17ED_4894_1A08_F981)
        XCTAssertEqual(p, 0x494C_553B)
        XCTAssertEqual(q, 0x5391_1073)
    }

    // MARK: TL

    func testEncodesMethodLikeProbe() throws {
        var writer = TLWriter()
        try writer.object(TLObject("messages.sendMessage", [
            "peer": .object(TLObject("inputPeerUser", ["user_id": .long(123_456_789_012), "access_hash": .long(-987_654_321)])),
            "message": .string("héllo"),
            "random_id": .long(42),
            "reply_to": .object(TLObject("inputReplyToMessage", ["reply_to_msg_id": .int(7)])),
            "silent": .bool(true),
        ]))
        XCTAssertEqual(writer.data, Data(hex: "5ad15c54210000004ca5e8dd141a99be1c0000004f9721c5ffffffffc2b7d43b00000000070000000668c3a96c6c6f002a00000000000000"))
    }

    func testRoundTripsFlagsAndVectors() throws {
        let object = TLObject("messages.sendMessage", [
            "peer": .object(TLObject("inputPeerSelf")),
            "message": .string(String(repeating: "x", count: 300)),
            "random_id": .long(-1),
            "entities": .vector([.object(TLObject("messageEntityBold", ["offset": .int(0), "length": .int(3)]))]),
        ])
        var writer = TLWriter()
        try writer.object(object)
        var reader = TLReader(writer.data)
        let decoded = try reader.value(.boxed("Object")).object
        XCTAssertEqual(decoded, object)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testDecodesGzipPackedResult() throws {
        let gzip = Data(hex: "1f8b08000000000002ff2b49cd494d2f4acc2d19a4340054e342d8a0000000")
        XCTAssertEqual(try TLReader.gunzip(gzip), Data(String(repeating: "telegram", count: 20).utf8))
    }

    func testSchemaHasLayerAndMethods() throws {
        let schema = TLSchema.shared
        XCTAssertGreaterThan(schema.layer, 200)
        XCTAssertEqual(try schema.resultType(of: TLObject("invokeWithLayer", ["query": .object(TLObject("help.getConfig"))])), .boxed("Config"))
        XCTAssertEqual(try schema.resultType(of: TLObject("messages.getHistory")), .boxed("messages.Messages"))
    }

    // MARK: Messages

    func testPreviewsMediaAndService() {
        let voice = TelegramClient.message(TLObject("message", [
            "id": .int(5), "date": .int(1_700_000_000), "message": .string(""), "out": .bool(true),
            "peer_id": .object(TLObject("peerUser", ["user_id": .long(9)])),
            "media": .object(TLObject("messageMediaDocument", ["document": .object(TLObject("document", [
                "attributes": .vector([.object(TLObject("documentAttributeAudio", ["voice": .bool(true), "duration": .int(3)]))]),
            ]))])),
        ]))
        XCTAssertEqual(voice.text, "Voice message")
        XCTAssertTrue(voice.isOutgoing)
        XCTAssertEqual(voice.senderId, 9)

        let caption = TelegramClient.message(TLObject("message", [
            "id": .int(6), "date": .int(0), "message": .string("look"),
            "from_id": .object(TLObject("peerUser", ["user_id": .long(3)])),
            "peer_id": .object(TLObject("peerChat", ["chat_id": .long(4)])),
            "media": .object(TLObject("messageMediaPhoto")),
            "reply_to": .object(TLObject("messageReplyHeader", ["reply_to_msg_id": .int(2)])),
        ]))
        XCTAssertEqual(caption.text, "Photo · look")
        XCTAssertEqual(caption.senderId, 3)
        XCTAssertEqual(caption.replyToId, 2)

        let service = TelegramClient.message(TLObject("messageService", [
            "id": .int(7), "date": .int(0), "peer_id": .object(TLObject("peerChat", ["chat_id": .long(4)])),
            "action": .object(TLObject("messageActionChatEditTitle", ["title": .string("Friends")])),
        ]))
        XCTAssertTrue(service.isService)
        // Without a sender, the actor is "Someone", as in Telegram.
        XCTAssertEqual(service.text, "Someone changed the group name to “Friends”")
    }

    func testMediaURLRoundTripsItsLocation() throws {
        let location = TLObject("inputPhotoFileLocation", [
            "id": .long(42), "access_hash": .long(-7), "file_reference": .bytes(Data([1, 2, 3, 255])), "thumb_size": .string("y"),
        ])
        let url = try XCTUnwrap(TelegramMediaURL.make(key: "photo-42-y", dc: 4, location: location))
        XCTAssertEqual(url.scheme, "tgfile")
        let parsed = try XCTUnwrap(TelegramMediaURL.parse(url))
        XCTAssertEqual(parsed.key, "photo-42-y")
        XCTAssertEqual(parsed.dc, 4)
        XCTAssertEqual(parsed.location, location)
    }

    /// Size shapes from a Saved Messages photo read with the probe.
    func testPicksLargestPhotoSizeWithinLimit() {
        let sizes = [
            TLObject("photoStrippedSize", ["type": .string("i"), "bytes": .bytes(Data())]),
            TLObject("photoSize", ["type": .string("m"), "w": .int(148), "h": .int(320), "size": .int(1)]),
            TLObject("photoSize", ["type": .string("y"), "w": .int(590), "h": .int(1280), "size": .int(1)]),
            TLObject("photoSizeProgressive", ["type": .string("w"), "w": .int(1179), "h": .int(2556), "sizes": .vector([])]),
        ]
        XCTAssertEqual(TelegramMediaParser.bestSize(sizes)?.type, "y")
        XCTAssertEqual(TelegramMediaParser.bestSize(sizes, maxSide: 100)?.type, "m")
    }

    func testParsesReactions() {
        let message = TLObject("message", ["reactions": .object(TLObject("messageReactions", [
            "results": .vector([
                .object(TLObject("reactionCount", ["reaction": .object(TLObject("reactionEmoji", ["emoticon": .string("👍")])), "count": .int(3), "chosen_order": .int(0)])),
                .object(TLObject("reactionCount", ["reaction": .object(TLObject("reactionCustomEmoji", ["document_id": .long(1)])), "count": .int(1)])),
            ]),
        ]))])
        let parsed = TelegramMediaParser.reactions(of: message)
        XCTAssertEqual(parsed.totals, [TelegramReaction(emoji: "👍", count: 3, isMine: true), TelegramReaction(emoji: "⭐️", count: 1, isMine: false)])
    }

    /// Shapes seen with `scripts/telegram-client.py listen`.
    func testUpdatesConcernOnlyTheirChat() {
        let group = TelegramPeer(kind: .channel, id: 2_009_589_709, accessHash: 1)
        let dm = TelegramPeer(kind: .user, id: 185_733_531, accessHash: 2)
        let channelMessage = TLObject("updates", ["updates": .vector([.object(TLObject("updateNewChannelMessage", [
            "message": .object(TLObject("message", ["id": .int(92290), "peer_id": .object(TLObject("peerChannel", ["channel_id": .long(2_009_589_709)]))])),
        ]))])])
        let status = TLObject("updateShort", ["update": .object(TLObject("updateUserStatus", ["user_id": .long(185_733_531)]))])
        let shortMessage = TLObject("updateShortMessage", ["user_id": .long(185_733_531), "id": .int(5)])

        XCTAssertTrue(TelegramClient.update(channelMessage, concerns: group))
        XCTAssertFalse(TelegramClient.update(channelMessage, concerns: dm))
        XCTAssertFalse(TelegramClient.update(status, concerns: dm))
        XCTAssertTrue(TelegramClient.update(shortMessage, concerns: dm))
        XCTAssertFalse(TelegramClient.update(shortMessage, concerns: group))
    }

    func testStatusUpdatesForTheirUser() {
        let status = TLObject("updateShort", ["update": .object(TLObject("updateUserStatus", [
            "user_id": .long(185_733_531),
            "status": .object(TLObject("userStatusOffline", ["was_online": .int(1_793_170_332)])),
        ]))])
        XCTAssertEqual(TelegramClient.statusUpdate(status, userId: 185_733_531), .lastSeen(Date(timeIntervalSince1970: 1_793_170_332)))
        XCTAssertNil(TelegramClient.statusUpdate(status, userId: 1))
        XCTAssertEqual(TelegramMember.Status.recently.text, "last seen recently")
    }

    // MARK: Spoilers

    func testSpoilerEntitiesAndMaskedPreview() {
        let message = TelegramClient.message(TLObject("message", [
            "id": .int(1), "date": .int(0), "message": .string("the answer is 42 ok"),
            "media": .object(TLObject("messageMediaPhoto", [:])),
            "entities": .vector([.object(TLObject("messageEntitySpoiler", ["offset": .int(14), "length": .int(2)]))]),
        ]))
        XCTAssertEqual(message.spoilers, [NSRange(location: 14, length: 2)])
        XCTAssertFalse(message.previewText.contains("42"))
        XCTAssertTrue(message.previewText.hasSuffix("the answer is ⠿⠿⠿ ok"))
    }

    func testServiceAccountLoginCodeIsHidden() {
        let text = "Login code: 12345. Do not give this code to anyone.\n\nSent 2026-10-28 at 10:00."
        XCTAssertEqual(SpoilerText.loginCodeRanges(in: text), [NSRange(location: 12, length: 5)])
        let web = "This is your login code:\nAb3d-Ef6g\n\nDo not give this code to anyone."
        XCTAssertEqual(SpoilerText.mask(web, ranges: SpoilerText.loginCodeRanges(in: web)), "This is your login code:\n⠿⠿⠿⠿⠿⠿⠿⠿\n\nDo not give this code to anyone.")
        let message = TelegramClient.message(TLObject("message", [
            "id": .int(2), "date": .int(0), "message": .string(text),
            "peer_id": .object(TLObject("peerUser", ["user_id": .long(777_000)])),
        ]))
        XCTAssertEqual(message.spoilers, [NSRange(location: 12, length: 5)])
        let other = TelegramClient.message(TLObject("message", [
            "id": .int(3), "date": .int(0), "message": .string(text),
            "peer_id": .object(TLObject("peerUser", ["user_id": .long(42)])),
        ]))
        XCTAssertNil(other.spoilers)
    }

    func testServiceAccountPushHidesTheCode() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "MESSAGE_TEXT", "loc-args": ["Telegram", "Login code: 12345. Do not give this code to anyone."]]],
            "custom": ["from_id": "777000"],
        ]
        let push = TelegramPushNotification.make(userInfo: userInfo) { _, _ in nil }
        XCTAssertEqual(push?.body, "Login code: ⠿⠿⠿⠿⠿. Do not give this code to anyone.")
    }

    // MARK: Push

    func testPrivateTextPushShowsTheSenderAndText() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "MESSAGE_TEXT", "loc-args": ["Ann", "hi there"]], "mutable-content": 1],
            "custom": ["from_id": "42", "msg_id": "7"],
        ]
        let push = TelegramPushNotification.make(userInfo: userInfo) { _, _ in nil }
        XCTAssertEqual(push?.title, "Ann")
        XCTAssertEqual(push?.body, "hi there")
        XCTAssertEqual(push?.senderId, 42)
        XCTAssertEqual(push?.conversationId, "user:42")
    }

    func testGroupPushNamesTheGroupAndKeepsTheLineForMedia() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "CHAT_MESSAGE_PHOTO", "loc-args": ["Ann", "Friends"]]],
            "custom": ["channel_id": 99, "chat_from_id": 42],
        ]
        let push = TelegramPushNotification.make(userInfo: userInfo) { key, args in "\(args[0]) sent a photo to the group \(args[1]) (\(key))" }
        XCTAssertEqual(push?.title, "Ann in Friends")
        XCTAssertEqual(push?.body, "Ann sent a photo to the group Friends (CHAT_MESSAGE_PHOTO)")
        XCTAssertEqual(push?.senderId, 42)
        XCTAssertEqual(push?.conversationId, "channel:99")
        XCTAssertEqual(push?.senderName, "Ann")
        XCTAssertEqual(push?.group, TelegramPushNotification.Group(id: 99, name: "Friends"))
    }

    func testPushWithTopLevelFieldsAndLocalizedAlert() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Ann", "body": "hi there"]],
            "from_id": 42,
        ]
        let push = TelegramPushNotification.make(userInfo: userInfo) { _, _ in nil }
        XCTAssertEqual(push?.title, "Ann")
        XCTAssertEqual(push?.body, "hi there")
        XCTAssertEqual(push?.conversationId, "user:42")
        XCTAssertEqual(TelegramPushChat(userInfo: userInfo), .user(42))
    }

    func testApronPushIsNotTelegram() {
        XCTAssertNil(TelegramPushChat(userInfo: ["apron": ["server": "https://example.com"], "from_id": "1"]))
        XCTAssertNil(TelegramPushChat(userInfo: ["webpush": "abc"]))
    }

    func testChannelPostPushHasNoPerson() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "CHANNEL_MESSAGE_TEXT", "loc-args": ["News", "Headline"]]],
            "custom": ["channel_id": 99],
        ]
        XCTAssertNil(TelegramPushNotification.make(userInfo: userInfo) { _, _ in nil })
    }

    // MARK: Live

    /// Creates an auth key with Telegram's DC 2; run with `TEST_RUNNER_TELEGRAM_LIVE_TESTS=1`.
    func testLiveHandshake() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELEGRAM_LIVE_TESTS"] == "1", "Set TELEGRAM_LIVE_TESTS=1 to reach Telegram")
        let transport = try TelegramTransport(host: XCTUnwrap(MTProtoSession.addresses[2]))
        try await transport.start()
        defer { transport.close() }
        let key = try await MTProtoSession.createAuthKey(transport: transport, dc: 2)
        XCTAssertEqual(key.authKey.count, 256)
        XCTAssertLessThan(abs(key.timeOffset), 120)
    }
}
