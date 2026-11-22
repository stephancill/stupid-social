import CryptoKit
import Foundation
@testable import StupidSocialCore
import XCTest

/// Vectors come from `scripts/whatsapp-client.py` (its node codec, `client_payload` and whatsmeow's compiled
/// protos), with synthetic names and keys.
final class WhatsAppCodecTests: XCTestCase {
    private typealias JID = WhatsAppJID
    private typealias Node = WhatsAppNode
    private typealias P = WhatsAppProto

    private func pattern(_ count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % 251) })
    }

    private func roundTrip(_ node: Node, _ hex: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(node.encoded().hex, hex, file: file, line: line)
        XCTAssertEqual(try Node.decode(frame: Data(hex: hex)), node, file: file, line: line)
    }

    // MARK: JIDs

    func testJIDParsingFormattingAndSignalAddresses() throws {
        let cases: [(String, JID, String, String)] = [
            ("15551234567@s.whatsapp.net", JID(user: "15551234567", server: "s.whatsapp.net"), "15551234567.0", "15551234567@s.whatsapp.net"),
            ("15551234567:7@s.whatsapp.net", JID(user: "15551234567", server: "s.whatsapp.net", device: 7), "15551234567.7", "15551234567@s.whatsapp.net"),
            ("123456789012345:12@lid", JID(user: "123456789012345", server: "lid", device: 12), "123456789012345_1.12", "123456789012345@lid"),
            ("15551234567.1:3@s.whatsapp.net", JID(user: "15551234567", server: "s.whatsapp.net", device: 3, agent: 1), "15551234567_1.3", "15551234567@s.whatsapp.net"),
            ("1555:2@hosted", JID(user: "1555", server: "hosted", device: 2), "1555_128.2", "1555@hosted"),
            ("1555:2@hosted.lid", JID(user: "1555", server: "hosted.lid", device: 2), "1555_129.2", "1555@hosted.lid"),
            ("120363000000000001@g.us", JID(user: "120363000000000001", server: "g.us"), "120363000000000001.0", "120363000000000001@g.us"),
            ("s.whatsapp.net", JID.server, ".0", "s.whatsapp.net"),
            ("status@broadcast", JID(user: "status", server: "broadcast"), "status.0", "status@broadcast"),
        ]
        for (text, jid, signal, nonAD) in cases {
            XCTAssertEqual(JID(string: text), jid, text)
            XCTAssertEqual(jid.description, text)
            XCTAssertEqual(jid.signalAddress, signal, text)
            XCTAssertEqual(jid.nonAD.description, nonAD, text)
        }
        XCTAssertNil(JID(string: "abc:x@lid"))
        let encoded = try JSONEncoder().encode([JID(user: "1", server: "lid", device: 2)])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["1:2@lid"]"#)
        XCTAssertEqual(try JSONDecoder().decode([JID].self, from: encoded), [JID(user: "1", server: "lid", device: 2)])
    }

    // MARK: Nodes

    func testIQMatchesProbe() throws {
        let node = Node("iq", ["id": "1234.5678-9", "to": .jid(.server), "type": "get", "xmlns": "encrypt", "t": "1700000000", "empty": ""], children: [Node("count")])
        XCTAssertEqual(node.encoded().hex, Vectors.nodeIQ)
        var decoded = node
        decoded["empty"] = nil
        XCTAssertEqual(try Node.decode(frame: Data(hex: Vectors.nodeIQ)), decoded)
        XCTAssertEqual(decoded.jid("to"), .server)
        XCTAssertEqual(decoded.attr("t"), "1700000000")
        XCTAssertNotNil(decoded.child("count"))
    }

    func testJIDAttributesMatchProbe() throws {
        let node = Node("message", [
            "from": .jid(JID(user: "15551234567", server: "s.whatsapp.net", device: 3)),
            "participant": .jid(JID(user: "123456789012345", server: "lid", device: 12)),
            "hosted": .jid(JID(user: "15559876543", server: "hosted", device: 2)),
            "to": .jid(JID(user: "15551234567", server: "s.whatsapp.net")),
            "recipient": .jid(JID(user: "123456789012345", server: "lid")),
            "group": .jid(JID(user: "120363000000000001", server: "g.us")),
            "status": .jid(JID(user: "status", server: "broadcast")),
        ])
        try roundTrip(node, Vectors.nodeJIDs)
    }

    func testPackedStringsMatchProbe() throws {
        let node = Node("x", [
            "a": "ABCDEF0123", "b": "ABC", "c": "12-3.45", "d": "123",
            "e": .string(String(repeating: "1", count: 127)),
            "f": .string(String(repeating: "2", count: 128)),
            "g": "abc", "h": "AB-1",
        ])
        try roundTrip(node, Vectors.nodePacked)
    }

    func testTokensMatchProbe() throws {
        let node = Node("read-self", ["profile_picture": "1724", "reaction": "pricing_model", "type": "result"], content: .string("result"))
        try roundTrip(node, Vectors.nodeTokens)
        XCTAssertEqual(try Node.decode(frame: Data(hex: Vectors.nodeTokens)).bytes, Data("result".utf8))
    }

    func testBinaryContentMatchesProbe() throws {
        try roundTrip(Node("enc", ["v": "2", "type": "msg"], bytes: Data()), Vectors.nodeBinary0)
        try roundTrip(Node("enc", ["v": "2", "type": "msg"], bytes: pattern(255)), Vectors.nodeBinary255)
        try roundTrip(Node("enc", ["v": "2", "type": "msg"], bytes: pattern(256)), Vectors.nodeBinary256)
        for (node, prefix, digest) in [
            (Node("enc", ["v": "2"], bytes: pattern(70000)), Vectors.nodeBinary70000Prefix, Vectors.nodeBinary70000SHA256),
            (Node("enc", bytes: pattern(1 << 20)), Vectors.nodeBinaryMiBPrefix, Vectors.nodeBinaryMiBSHA256),
        ] {
            let encoded = node.encoded()
            XCTAssertEqual(encoded.prefix(16).hex, prefix)
            XCTAssertEqual(Data(SHA256.hash(data: encoded)).hex, digest)
            XCTAssertEqual(try Node.decode(frame: encoded), node)
        }
    }

    func testNestedListsMatchProbe() throws {
        let items = (0 ..< 300).map { Node("item", ["id": .string("3EB0" + String(format: "%018X", $0))]) }
        let node = Node("iq", ["type": "set"], children: [
            Node("sync", children: [Node("collection", ["name": "regular_high", "version": "12"]), Node("collection", ["name": "critical_block"])]),
            Node("list", children: items),
            Node("empty", children: []),
        ])
        XCTAssertEqual(node.encoded().hex, Vectors.nodeNested)
        let decoded = try Node.decode(frame: Data(hex: Vectors.nodeNested))
        XCTAssertEqual(decoded.child("list")?.children.count, 300)
        XCTAssertEqual(decoded.child("sync", "collection")?.attr("name"), "regular_high")
        // An empty list encodes as LIST_EMPTY, which decodes as no content.
        XCTAssertEqual(decoded.child("empty")?.content, WhatsAppNode.Content.none)
        XCTAssertEqual(decoded.children.prefix(2), node.children.prefix(2))
    }

    func testCompressedFrameDecodes() throws {
        let node = Node("notification", ["type": "encrypt", "from": .jid(.server)], children: [Node("count", ["value": "3"]), Node("blob", bytes: pattern(600))])
        XCTAssertEqual(node.encoded().hex, Vectors.nodeCompressedPlain)
        XCTAssertEqual(try Node.decode(frame: Data(hex: Vectors.nodeCompressedFrame)), node)
        var corrupt = Data(hex: Vectors.nodeCompressedFrame)
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try Node.decode(frame: corrupt))
    }

    func testDecodeRejectsMalformedFrames() {
        XCTAssertThrowsError(try Node.decode(frame: Data()))
        XCTAssertThrowsError(try Node.decode(frame: Data(hex: Vectors.nodeIQ).dropLast()))
        XCTAssertThrowsError(try Node.decode(frame: Data(hex: Vectors.nodeIQ) + Data([0])))
    }

    func testDescriptionNeverPrintsContent() {
        let node = Node("message", ["id": "1"], children: [Node("enc", bytes: Data("secret".utf8)), Node("body", content: .string("hello"))])
        XCTAssertEqual(node.description, "<message id=\"1\">\n  <enc>[6 bytes]</enc>\n  <body>[5 chars]</body>\n</message>")
    }

    // MARK: Login and handshake

    func testClientPayloadsMatchProbe() {
        let version = P.AppVersion(2, 3000, 1_050_728_964)
        let login = P.ClientPayload(version: version, mode: .login(username: 15_551_234_567, device: 7))
        XCTAssertEqual(login.serialized().hex, Vectors.clientPayloadLogin)
        let registration = P.DevicePairingRegistrationData(
            registrationID: 0x1234_5678,
            identityKey: Data(0 ..< 32),
            signedPreKeyID: 1,
            signedPreKey: Data(32 ..< 64),
            signedPreKeySignature: Data(64 ..< 128),
        )
        XCTAssertEqual(P.ClientPayload(version: version, mode: .registration(registration)).serialized().hex, Vectors.clientPayloadRegistration)
        XCTAssertEqual(P.DeviceProps().serialized().hex, Vectors.deviceProps)
    }

    func testHandshakeMessagesMatchProbe() throws {
        XCTAssertEqual(P.HandshakeMessage(clientHello: .init(ephemeral: Data(0 ..< 32))).serialized().hex, Vectors.clientHello)
        let server = try P.HandshakeMessage(data: Data(hex: Vectors.serverHello)).serverHello
        XCTAssertEqual(server, .init(ephemeral: Data(1 ..< 33), staticKey: Data(2 ..< 50), payload: Data(3 ..< 103)))
        let finish = P.HandshakeMessage(clientFinish: .init(staticKey: Data(4 ..< 52), payload: Data(5 ..< 205)))
        XCTAssertEqual(finish.serialized().hex, Vectors.clientFinish)

        let chain = try P.CertChain(data: Data(hex: Vectors.certChain))
        let intermediate = try P.CertChain.Details(data: XCTUnwrap(chain.intermediate).details)
        XCTAssertEqual(intermediate.serial, 7)
        XCTAssertEqual(intermediate.issuerSerial, 0)
        XCTAssertEqual(intermediate.key, Data(0 ..< 32))
        XCTAssertEqual(intermediate.notBefore, 1_700_000_000)
        XCTAssertEqual(intermediate.notAfter, 1_900_000_000)
        XCTAssertEqual(chain.intermediate?.signature, Data(count: 64))
        let leaf = try P.CertChain.Details(data: XCTUnwrap(chain.leaf).details)
        XCTAssertEqual(leaf.issuerSerial, 7)
        XCTAssertEqual(leaf.key, Data(1 ..< 33))
    }

    func testADVIdentityReserializesLikeProbe() throws {
        let container = try P.ADVSignedDeviceIdentityHMAC(data: Data(hex: Vectors.advHMAC))
        XCTAssertEqual(container.accountType, .hosted)
        XCTAssertEqual(container.hmac, Data(0 ..< 32))
        var identity = try P.ADVSignedDeviceIdentity(data: container.details)
        XCTAssertEqual(identity.accountSignatureKey, Data(0 ..< 32))
        XCTAssertEqual(identity.accountSignature, Data(0 ..< 64))
        XCTAssertNil(identity.deviceSignature)
        let details = try P.ADVDeviceIdentity(data: XCTUnwrap(identity.details))
        XCTAssertEqual(details.rawID, 99)
        XCTAssertEqual(details.keyIndex, 4)
        XCTAssertEqual(details.timestamp, 1_700_000_000)
        XCTAssertEqual(details.accountType, .e2ee)
        XCTAssertEqual(details.deviceType, .e2ee)

        identity.deviceSignature = Data(100 ..< 164)
        XCTAssertEqual(identity.serialized().hex, Vectors.advSignedWithDevice)
        identity.accountSignatureKey = nil
        XCTAssertEqual(identity.serialized().hex, Vectors.advSignedForServer)
        // Setting a field that comes before others keeps field-number order.
        var reordered = try P.ADVSignedDeviceIdentity(data: Data(hex: Vectors.advSignedForServer))
        reordered.accountSignatureKey = Data(0 ..< 32)
        XCTAssertEqual(reordered.serialized().hex, Vectors.advSignedWithDevice)
    }

    // MARK: Messages

    func testBuiltMessagesMatchProbe() throws {
        XCTAssertEqual(P.Message.text("hello there").serialized().hex, Vectors.messageText)
        let reply = P.Message.text("a reply", contextInfo: P.ContextInfo(
            stanzaID: "3EB0AAAA",
            participant: "123456789012345@lid",
            quotedMessage: .text("the original"),
            mentionedJIDs: ["111@lid", "222@lid"],
        ))
        XCTAssertEqual(reply.serialized().hex, Vectors.messageReply)
        let key = P.MessageKey(remoteJID: "123456789012345@lid", fromMe: true, id: "3EB0BBBB")
        XCTAssertEqual(P.Message.reaction(to: key, text: "👍", senderTimestampMS: 1_700_000_000_123).serialized().hex, Vectors.messageReaction)
        let groupKey = P.MessageKey(remoteJID: "120363000000000001@g.us", fromMe: false, id: "ABCD", participant: "111@lid")
        XCTAssertEqual(P.Message.reaction(to: groupKey, text: "", senderTimestampMS: 5).serialized().hex, Vectors.messageReactionRemove)
        let inner = try P.Message(data: Data(hex: Vectors.messageInnerWithContext))
        XCTAssertEqual(P.Message.deviceSent(inner, destinationJID: "123456789012345@lid").serialized().hex, Vectors.messageDeviceSent)
    }

    func testTextMessagesDecode() throws {
        let reply = try P.Message(data: Data(hex: Vectors.messageReply))
        XCTAssertNil(reply.conversation)
        let extended = try XCTUnwrap(reply.extendedText)
        XCTAssertEqual(extended.text, "a reply")
        XCTAssertEqual(extended.contextInfo?.stanzaID, "3EB0AAAA")
        XCTAssertEqual(extended.contextInfo?.participant, "123456789012345@lid")
        XCTAssertEqual(extended.contextInfo?.quotedMessage?.conversation, "the original")
        XCTAssertEqual(extended.contextInfo?.mentionedJIDs, ["111@lid", "222@lid"])
        XCTAssertEqual(reply.unknownFieldNumbers, [])

        let link = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageLink)).extendedText)
        XCTAssertEqual(link.matchedText, "https://example.com")
        XCTAssertEqual(link.title, "Example")
        XCTAssertEqual(link.description, "An example page")
        XCTAssertEqual(link.jpegThumbnail, Data([0xFF, 0xD8]) + Data("thumb".utf8))

        let reaction = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageReactionRemove)).reaction)
        XCTAssertEqual(reaction.key, P.MessageKey(remoteJID: "120363000000000001@g.us", fromMe: false, id: "ABCD", participant: "111@lid"))
        XCTAssertEqual(reaction.text, "")
        XCTAssertEqual(reaction.senderTimestampMS, 5)

        let sent = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageDeviceSent)).deviceSent)
        XCTAssertEqual(sent.destinationJID, "123456789012345@lid")
        XCTAssertEqual(sent.message?.conversation, "hello there")
        XCTAssertNotNil(sent.message?.messageContextInfo)

        let group = try P.Message(data: Data(hex: Vectors.messageSenderKey))
        XCTAssertEqual(group.conversation, "group hello")
        XCTAssertEqual(group.senderKeyDistribution?.groupID, "120363000000000001@g.us")
        XCTAssertEqual(group.senderKeyDistribution?.axolotlSenderKeyDistributionMessage, Data([0x33]) + Data("skdm".utf8))
    }

    func testMediaMessagesDecode() throws {
        let ephemeral = try P.Message(data: Data(hex: Vectors.messageEphemeralImage))
        XCTAssertNil(ephemeral.media)
        let image = try XCTUnwrap(ephemeral.unwrapped.media)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.url, "https://mmg.whatsapp.net/x")
        XCTAssertEqual(image.mimetype, "image/jpeg")
        XCTAssertEqual(image.caption, "a caption")
        XCTAssertEqual(image.fileSHA256, Data(repeating: 1, count: 32))
        XCTAssertEqual(image.fileLength, 12345)
        XCTAssertEqual(image.height, 480)
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.mediaKey, Data(repeating: 2, count: 32))
        XCTAssertEqual(image.fileEncSHA256, Data(repeating: 3, count: 32))
        XCTAssertEqual(image.directPath, "/v/t62/x")
        XCTAssertEqual(image.jpegThumbnail, Data([0xFF, 0xD8]))
        XCTAssertEqual(image.contextInfo?.stanzaID, "Q1")

        let video = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageViewOnceVideo)).unwrapped.media)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.seconds, 12)
        XCTAssertEqual(video.caption, "clip")
        XCTAssertEqual(video.height, 720)
        XCTAssertEqual(video.width, 1280)
        XCTAssertEqual(video.directPath, "/v/video")

        let audio = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageAudio)).media)
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.seconds, 7)
        XCTAssertEqual(audio.ptt, true)
        XCTAssertEqual(audio.fileLength, 999)
        XCTAssertEqual(audio.mimetype, "audio/ogg; codecs=opus")

        let document = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageDocument)).unwrapped.media)
        XCTAssertEqual(document.kind, .document)
        XCTAssertEqual(document.fileName, "report.pdf")
        XCTAssertEqual(document.caption, "the report")
        XCTAssertEqual(document.title, "report")
        XCTAssertEqual(document.fileLength, 2048)

        let sticker = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageSticker)).media)
        XCTAssertEqual(sticker.kind, .sticker)
        XCTAssertEqual(sticker.mimetype, "image/webp")
        XCTAssertEqual(sticker.isAnimated, true)
        XCTAssertEqual(sticker.width, 512)
    }

    func testOtherMessagesDecode() throws {
        let contact = try P.Message(data: Data(hex: Vectors.messageContact)).contact
        XCTAssertEqual(contact?.displayName, "Some Contact")
        XCTAssertEqual(contact?.vcard, "BEGIN:VCARD")
        let location = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageLocation)).location)
        XCTAssertEqual(location.latitude, -33.9)
        XCTAssertEqual(location.longitude, 18.4)
        XCTAssertEqual(location.name, "Somewhere")
        XCTAssertFalse(location.isLive)
        let poll = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messagePoll)).poll)
        XCTAssertEqual(poll.name, "Lunch?")
        XCTAssertEqual(poll.options, ["Yes", "No"])
        let unknown = try P.Message(data: Data(hex: Vectors.messageUnknown))
        XCTAssertEqual(unknown.unknownFieldNumbers, [42])
        XCTAssertNotNil(unknown.messageContextInfo)
    }

    func testProtocolMessagesDecode() throws {
        let edit = try P.Message(data: Data(hex: Vectors.messageEdit))
        XCTAssertNil(edit.protocolMessage)
        let editProtocol = try XCTUnwrap(edit.unwrapped.protocolMessage)
        XCTAssertEqual(editProtocol.kind, .messageEdit)
        XCTAssertEqual(editProtocol.key, P.MessageKey(remoteJID: "123@lid", fromMe: true, id: "3EB0CCCC"))
        XCTAssertEqual(editProtocol.editedMessage?.conversation, "edited text")
        XCTAssertEqual(editProtocol.timestampMS, 1_700_000_000_999)

        let revoke = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageRevoke)).protocolMessage)
        XCTAssertEqual(revoke.kind, .revoke)
        XCTAssertEqual(revoke.key?.id, "3EB0DDDD")
        XCTAssertNil(revoke.key?.fromMe)

        let history = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageHistoryNotification)).protocolMessage)
        XCTAssertEqual(history.kind, .historySyncNotification)
        let notification = try XCTUnwrap(history.historySyncNotification)
        XCTAssertEqual(notification.fileSHA256, Data(repeating: 4, count: 32))
        XCTAssertEqual(notification.fileLength, 4096)
        XCTAssertEqual(notification.mediaKey, Data(repeating: 5, count: 32))
        XCTAssertEqual(notification.fileEncSHA256, Data(repeating: 6, count: 32))
        XCTAssertEqual(notification.directPath, "/v/hist")
        XCTAssertEqual(notification.syncType, 3)
        XCTAssertEqual(notification.chunkOrder, 2)
        XCTAssertEqual(notification.progress, 40)
        XCTAssertEqual(notification.originalMessageID, "ORIG")
        XCTAssertEqual(notification.initialHistBootstrapInlinePayload, Data("inline".utf8))

        let share = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageKeyShare)).protocolMessage)
        XCTAssertEqual(share.kind, .appStateSyncKeyShare)
        let keys = try XCTUnwrap(share.appStateSyncKeyShare).keys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].keyID, Data([0, 0, 1]))
        XCTAssertEqual(keys[0].keyData, Data(repeating: 7, count: 32))
        XCTAssertEqual(keys[0].fingerprint?.hex, Vectors.keyShareFingerprint)
        XCTAssertEqual(keys[0].timestamp, 1_700_000_000_000)
        XCTAssertEqual(keys[1].keyID, Data([0, 0, 2]))
        XCTAssertNil(keys[1].fingerprint)

        let lid = try XCTUnwrap(P.Message(data: Data(hex: Vectors.messageLIDMigration)).protocolMessage)
        XCTAssertEqual(lid.kind, .lidMigrationMappingSync)
        let payload = try P.LIDMigrationMappingSyncPayload(data: XCTUnwrap(lid.lidMigrationMappingPayload))
        XCTAssertEqual(payload.mappings, [
            .init(pn: 15_551_234_567, assignedLID: 123_456_789_012_345),
            .init(pn: 15_559_876_543, assignedLID: 987_654_321_098_765),
        ])
    }

    // MARK: History sync and app state

    func testHistorySyncDecodes() throws {
        XCTAssertEqual(try WhatsAppZlib.decompress(Data(hex: Vectors.historySyncZlib)).hex, Vectors.historySync)
        let history = try P.HistorySync(data: Data(hex: Vectors.historySync))
        XCTAssertEqual(history.syncType, .recent)
        XCTAssertEqual(history.chunkOrder, 3)
        XCTAssertEqual(history.progress, 55)
        XCTAssertEqual(history.pushnames, [.init(id: "15551234567@s.whatsapp.net", pushname: "Alice")])
        XCTAssertEqual(history.phoneNumberToLIDMappings, [.init(pnJID: "15551234567@s.whatsapp.net", lidJID: "123456789012345@lid")])
        XCTAssertEqual(history.conversations.count, 2)

        let chat = history.conversations[0]
        XCTAssertEqual(chat.id, "123456789012345@lid")
        XCTAssertEqual(chat.name, "")
        XCTAssertEqual(chat.displayName, "Alice Example")
        XCTAssertEqual(chat.unreadCount, 2)
        XCTAssertTrue(chat.markedAsUnread)
        XCTAssertFalse(chat.archived)
        XCTAssertEqual(chat.pinned, 1_700_000_000)
        XCTAssertEqual(chat.muteEndTime, 1_900_000_000)
        XCTAssertEqual(chat.conversationTimestamp, 1_700_000_500)
        XCTAssertEqual(chat.lastMsgTimestamp, 1_700_000_400)
        XCTAssertEqual(chat.pnJID, "15551234567@s.whatsapp.net")
        XCTAssertEqual(chat.lidJID, "123456789012345@lid")
        XCTAssertEqual(chat.username, "alice")
        XCTAssertEqual(chat.ephemeralExpiration, 86400)
        XCTAssertEqual(chat.messages.count, 2)
        let first = chat.messages[0]
        XCTAssertEqual(first.key, P.MessageKey(remoteJID: "123456789012345@lid", fromMe: false, id: "MSG1"))
        XCTAssertEqual(first.message?.conversation, "hi")
        XCTAssertEqual(first.messageTimestamp, 1_700_000_400)
        XCTAssertEqual(first.status, 4)
        XCTAssertEqual(first.pushName, "Alice")
        XCTAssertEqual(first.reactions.first?.text, "❤️")
        XCTAssertEqual(first.reactions.first?.key?.fromMe, true)
        XCTAssertEqual(first.reactions.first?.senderTimestampMS, 1_700_000_450_000)
        let stub = chat.messages[1]
        XCTAssertNil(stub.message)
        XCTAssertEqual(stub.messageStubType, 132)
        XCTAssertEqual(stub.messageStubParameters, ["param1", "param2"])

        let group = history.conversations[1]
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertTrue(group.readOnly)
        XCTAssertEqual(group.participants, [.init(userJID: "111@lid", rank: 1), .init(userJID: "222@lid", rank: 0)])
        XCTAssertEqual(group.messages.first?.participant, "111@lid")
        XCTAssertEqual(group.messages.first?.key?.participant, "111@lid")
        XCTAssertEqual(group.messages.first?.message?.extendedText?.text, "group text")
    }

    func testServerSyncDecodes() throws {
        let blob = try P.ExternalBlobReference(data: Data(hex: Vectors.externalBlob))
        XCTAssertEqual(blob.mediaKey, Data(repeating: 9, count: 32))
        XCTAssertEqual(blob.directPath, "/v/blob")
        XCTAssertEqual(blob.handle, "h")
        XCTAssertEqual(blob.fileSizeBytes, 77)
        XCTAssertEqual(blob.fileSHA256, Data(repeating: 10, count: 32))
        XCTAssertEqual(blob.fileEncSHA256, Data(repeating: 11, count: 32))

        let snapshot = try P.SyncdSnapshot(data: Data(hex: Vectors.syncdSnapshot))
        XCTAssertEqual(snapshot.version, 42)
        XCTAssertEqual(snapshot.mac, Data(repeating: 14, count: 32))
        XCTAssertEqual(snapshot.keyID, Data([0, 0, 1]))
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records[0].index, Data(repeating: 12, count: 32))
        XCTAssertEqual(snapshot.records[0].value, Data(repeating: 13, count: 80))
        XCTAssertEqual(snapshot.records[0].keyID, Data([0, 0, 1]))

        let patch = try P.SyncdPatch(data: Data(hex: Vectors.syncdPatch))
        XCTAssertEqual(patch.version, 43)
        XCTAssertEqual(patch.mutations.map(\.operation), [.remove, .set])
        XCTAssertEqual(patch.mutations[0].record.value, Data(repeating: 16, count: 64))
        XCTAssertEqual(patch.mutations[1].record.index, Data(repeating: 17, count: 32))
        XCTAssertEqual(patch.externalMutations, blob)
        XCTAssertEqual(patch.snapshotMAC, Data(repeating: 18, count: 32))
        XCTAssertEqual(patch.patchMAC, Data(repeating: 19, count: 32))
        XCTAssertEqual(patch.keyID, Data([0, 0, 2]))
        XCTAssertEqual(patch.deviceIndex, 3)
        XCTAssertEqual(try P.SyncdMutations(data: Data(hex: Vectors.syncdMutations)).mutations, [patch.mutations[0]])
    }

    func testSyncActionsDecode() throws {
        let contact = try P.SyncActionData(data: Data(hex: Vectors.syncContact))
        XCTAssertEqual(String(decoding: contact.index, as: UTF8.self), #"["contact","15551234567@s.whatsapp.net"]"#)
        XCTAssertEqual(contact.version, 2)
        XCTAssertEqual(contact.value?.timestamp, 1_700_000_000_000)
        XCTAssertEqual(contact.value?.contactAction, .init(fullName: "Alice Example", firstName: "Alice", lidJID: "123456789012345@lid", pnJID: "15551234567@s.whatsapp.net", username: nil))

        let mute = try XCTUnwrap(P.SyncActionData(data: Data(hex: Vectors.syncMute)).value)
        XCTAssertEqual(mute.muteAction, .init(muted: true, muteEndTimestamp: -1))
        XCTAssertNil(mute.pinned)
        XCTAssertFalse(mute.deletesChat)

        let misc = try P.SyncActionData(data: Data(hex: Vectors.syncMisc))
        XCTAssertEqual(misc.version, 3)
        let value = try XCTUnwrap(misc.value)
        XCTAssertEqual(value.timestamp, 5)
        XCTAssertEqual(value.pinned, true)
        XCTAssertEqual(value.archived, true)
        XCTAssertEqual(value.read, false)
        XCTAssertTrue(value.deletesChat)
        XCTAssertTrue(value.clearsChat)
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private enum Vectors {
    static let nodeIQ = "00f80c1908ff861234b5678a9f11fa0003042916cb1aff051700000000f801f80141"
    static let nodeJIDs = "00f80f1306f70003ff8615551234567f05f7010cff88123456789012345ffc06686f73746564f78002ff8615559876543f11faff8615551234567f0394faff88123456789012345f76ecaafaff091203630000000000011c0bfa0b0d"
    static let nodePacked = "00f811fc0178fc0161fb05abcdef0123fc0162fb82abcfee25ff8412a3b45ffc0164ff82123fedebffc01111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111ffc0166fc803232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232fc0167fc03616263fc0168fc0441422d31"
    static let nodeTokens = "00f808ec00ef01ef00ec04ef09041414"
    static let nodeBinary0 = "00f8061d5145044dfc00"
    static let nodeBinary255 = "00f8061d5145044dfcff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa00010203"
    static let nodeBinary256 = "00f8061d5145044dfd000100000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa0001020304"
    static let nodeBinary70000Prefix = "00f8041d5145fd011170000102030405"
    static let nodeBinary70000SHA256 = "0cdad03d190da36783fe49539dfa34b533673750a9bcafff658d0e1d59c5873e"
    static let nodeBinaryMiBPrefix = "00f8021dfe0010000000010203040506"
    static let nodeBinaryMiBSHA256 = "a0172a9533f8e2bcd70875af768cbf2f6675bb9c6d71e19243ada6ab2f636364"
    static let nodeNested = "00f80419045af803f802ece3f802f805ec5b89eced54cff803ec5b89eea1f80271f9012cf8033f08fb0b3eb0000000000000000000f8033f08fb0b3eb0000000000000000001f8033f08fb0b3eb0000000000000000002f8033f08fb0b3eb0000000000000000003f8033f08fb0b3eb0000000000000000004f8033f08fb0b3eb0000000000000000005f8033f08fb0b3eb0000000000000000006f8033f08fb0b3eb0000000000000000007f8033f08fb0b3eb0000000000000000008f8033f08fb0b3eb0000000000000000009f8033f08fb0b3eb000000000000000000af8033f08fb0b3eb000000000000000000bf8033f08fb0b3eb000000000000000000cf8033f08fb0b3eb000000000000000000df8033f08fb0b3eb000000000000000000ef8033f08fb0b3eb000000000000000000ff8033f08fb0b3eb0000000000000000010f8033f08fb0b3eb0000000000000000011f8033f08fb0b3eb0000000000000000012f8033f08fb0b3eb0000000000000000013f8033f08fb0b3eb0000000000000000014f8033f08fb0b3eb0000000000000000015f8033f08fb0b3eb0000000000000000016f8033f08fb0b3eb0000000000000000017f8033f08fb0b3eb0000000000000000018f8033f08fb0b3eb0000000000000000019f8033f08fb0b3eb000000000000000001af8033f08fb0b3eb000000000000000001bf8033f08fb0b3eb000000000000000001cf8033f08fb0b3eb000000000000000001df8033f08fb0b3eb000000000000000001ef8033f08fb0b3eb000000000000000001ff8033f08fb0b3eb0000000000000000020f8033f08fb0b3eb0000000000000000021f8033f08fb0b3eb0000000000000000022f8033f08fb0b3eb0000000000000000023f8033f08fb0b3eb0000000000000000024f8033f08fb0b3eb0000000000000000025f8033f08fb0b3eb0000000000000000026f8033f08fb0b3eb0000000000000000027f8033f08fb0b3eb0000000000000000028f8033f08fb0b3eb0000000000000000029f8033f08fb0b3eb000000000000000002af8033f08fb0b3eb000000000000000002bf8033f08fb0b3eb000000000000000002cf8033f08fb0b3eb000000000000000002df8033f08fb0b3eb000000000000000002ef8033f08fb0b3eb000000000000000002ff8033f08fb0b3eb0000000000000000030f8033f08fb0b3eb0000000000000000031f8033f08fb0b3eb0000000000000000032f8033f08fb0b3eb0000000000000000033f8033f08fb0b3eb0000000000000000034f8033f08fb0b3eb0000000000000000035f8033f08fb0b3eb0000000000000000036f8033f08fb0b3eb0000000000000000037f8033f08fb0b3eb0000000000000000038f8033f08fb0b3eb0000000000000000039f8033f08fb0b3eb000000000000000003af8033f08fb0b3eb000000000000000003bf8033f08fb0b3eb000000000000000003cf8033f08fb0b3eb000000000000000003df8033f08fb0b3eb000000000000000003ef8033f08fb0b3eb000000000000000003ff8033f08fb0b3eb0000000000000000040f8033f08fb0b3eb0000000000000000041f8033f08fb0b3eb0000000000000000042f8033f08fb0b3eb0000000000000000043f8033f08fb0b3eb0000000000000000044f8033f08fb0b3eb0000000000000000045f8033f08fb0b3eb0000000000000000046f8033f08fb0b3eb0000000000000000047f8033f08fb0b3eb0000000000000000048f8033f08fb0b3eb0000000000000000049f8033f08fb0b3eb000000000000000004af8033f08fb0b3eb000000000000000004bf8033f08fb0b3eb000000000000000004cf8033f08fb0b3eb000000000000000004df8033f08fb0b3eb000000000000000004ef8033f08fb0b3eb000000000000000004ff8033f08fb0b3eb0000000000000000050f8033f08fb0b3eb0000000000000000051f8033f08fb0b3eb0000000000000000052f8033f08fb0b3eb0000000000000000053f8033f08fb0b3eb0000000000000000054f8033f08fb0b3eb0000000000000000055f8033f08fb0b3eb0000000000000000056f8033f08fb0b3eb0000000000000000057f8033f08fb0b3eb0000000000000000058f8033f08fb0b3eb0000000000000000059f8033f08fb0b3eb000000000000000005af8033f08fb0b3eb000000000000000005bf8033f08fb0b3eb000000000000000005cf8033f08fb0b3eb000000000000000005df8033f08fb0b3eb000000000000000005ef8033f08fb0b3eb000000000000000005ff8033f08fb0b3eb0000000000000000060f8033f08fb0b3eb0000000000000000061f8033f08fb0b3eb0000000000000000062f8033f08fb0b3eb0000000000000000063f8033f08fb0b3eb0000000000000000064f8033f08fb0b3eb0000000000000000065f8033f08fb0b3eb0000000000000000066f8033f08fb0b3eb0000000000000000067f8033f08fb0b3eb0000000000000000068f8033f08fb0b3eb0000000000000000069f8033f08fb0b3eb000000000000000006af8033f08fb0b3eb000000000000000006bf8033f08fb0b3eb000000000000000006cf8033f08fb0b3eb000000000000000006df8033f08fb0b3eb000000000000000006ef8033f08fb0b3eb000000000000000006ff8033f08fb0b3eb0000000000000000070f8033f08fb0b3eb0000000000000000071f8033f08fb0b3eb0000000000000000072f8033f08fb0b3eb0000000000000000073f8033f08fb0b3eb0000000000000000074f8033f08fb0b3eb0000000000000000075f8033f08fb0b3eb0000000000000000076f8033f08fb0b3eb0000000000000000077f8033f08fb0b3eb0000000000000000078f8033f08fb0b3eb0000000000000000079f8033f08fb0b3eb000000000000000007af8033f08fb0b3eb000000000000000007bf8033f08fb0b3eb000000000000000007cf8033f08fb0b3eb000000000000000007df8033f08fb0b3eb000000000000000007ef8033f08fb0b3eb000000000000000007ff8033f08fb0b3eb0000000000000000080f8033f08fb0b3eb0000000000000000081f8033f08fb0b3eb0000000000000000082f8033f08fb0b3eb0000000000000000083f8033f08fb0b3eb0000000000000000084f8033f08fb0b3eb0000000000000000085f8033f08fb0b3eb0000000000000000086f8033f08fb0b3eb0000000000000000087f8033f08fb0b3eb0000000000000000088f8033f08fb0b3eb0000000000000000089f8033f08fb0b3eb000000000000000008af8033f08fb0b3eb000000000000000008bf8033f08fb0b3eb000000000000000008cf8033f08fb0b3eb000000000000000008df8033f08fb0b3eb000000000000000008ef8033f08fb0b3eb000000000000000008ff8033f08fb0b3eb0000000000000000090f8033f08fb0b3eb0000000000000000091f8033f08fb0b3eb0000000000000000092f8033f08fb0b3eb0000000000000000093f8033f08fb0b3eb0000000000000000094f8033f08fb0b3eb0000000000000000095f8033f08fb0b3eb0000000000000000096f8033f08fb0b3eb0000000000000000097f8033f08fb0b3eb0000000000000000098f8033f08fb0b3eb0000000000000000099f8033f08fb0b3eb000000000000000009af8033f08fb0b3eb000000000000000009bf8033f08fb0b3eb000000000000000009cf8033f08fb0b3eb000000000000000009df8033f08fb0b3eb000000000000000009ef8033f08fb0b3eb000000000000000009ff8033f08fb0b3eb00000000000000000a0f8033f08fb0b3eb00000000000000000a1f8033f08fb0b3eb00000000000000000a2f8033f08fb0b3eb00000000000000000a3f8033f08fb0b3eb00000000000000000a4f8033f08fb0b3eb00000000000000000a5f8033f08fb0b3eb00000000000000000a6f8033f08fb0b3eb00000000000000000a7f8033f08fb0b3eb00000000000000000a8f8033f08fb0b3eb00000000000000000a9f8033f08fb0b3eb00000000000000000aaf8033f08fb0b3eb00000000000000000abf8033f08fb0b3eb00000000000000000acf8033f08fb0b3eb00000000000000000adf8033f08fb0b3eb00000000000000000aef8033f08fb0b3eb00000000000000000aff8033f08fb0b3eb00000000000000000b0f8033f08fb0b3eb00000000000000000b1f8033f08fb0b3eb00000000000000000b2f8033f08fb0b3eb00000000000000000b3f8033f08fb0b3eb00000000000000000b4f8033f08fb0b3eb00000000000000000b5f8033f08fb0b3eb00000000000000000b6f8033f08fb0b3eb00000000000000000b7f8033f08fb0b3eb00000000000000000b8f8033f08fb0b3eb00000000000000000b9f8033f08fb0b3eb00000000000000000baf8033f08fb0b3eb00000000000000000bbf8033f08fb0b3eb00000000000000000bcf8033f08fb0b3eb00000000000000000bdf8033f08fb0b3eb00000000000000000bef8033f08fb0b3eb00000000000000000bff8033f08fb0b3eb00000000000000000c0f8033f08fb0b3eb00000000000000000c1f8033f08fb0b3eb00000000000000000c2f8033f08fb0b3eb00000000000000000c3f8033f08fb0b3eb00000000000000000c4f8033f08fb0b3eb00000000000000000c5f8033f08fb0b3eb00000000000000000c6f8033f08fb0b3eb00000000000000000c7f8033f08fb0b3eb00000000000000000c8f8033f08fb0b3eb00000000000000000c9f8033f08fb0b3eb00000000000000000caf8033f08fb0b3eb00000000000000000cbf8033f08fb0b3eb00000000000000000ccf8033f08fb0b3eb00000000000000000cdf8033f08fb0b3eb00000000000000000cef8033f08fb0b3eb00000000000000000cff8033f08fb0b3eb00000000000000000d0f8033f08fb0b3eb00000000000000000d1f8033f08fb0b3eb00000000000000000d2f8033f08fb0b3eb00000000000000000d3f8033f08fb0b3eb00000000000000000d4f8033f08fb0b3eb00000000000000000d5f8033f08fb0b3eb00000000000000000d6f8033f08fb0b3eb00000000000000000d7f8033f08fb0b3eb00000000000000000d8f8033f08fb0b3eb00000000000000000d9f8033f08fb0b3eb00000000000000000daf8033f08fb0b3eb00000000000000000dbf8033f08fb0b3eb00000000000000000dcf8033f08fb0b3eb00000000000000000ddf8033f08fb0b3eb00000000000000000def8033f08fb0b3eb00000000000000000dff8033f08fb0b3eb00000000000000000e0f8033f08fb0b3eb00000000000000000e1f8033f08fb0b3eb00000000000000000e2f8033f08fb0b3eb00000000000000000e3f8033f08fb0b3eb00000000000000000e4f8033f08fb0b3eb00000000000000000e5f8033f08fb0b3eb00000000000000000e6f8033f08fb0b3eb00000000000000000e7f8033f08fb0b3eb00000000000000000e8f8033f08fb0b3eb00000000000000000e9f8033f08fb0b3eb00000000000000000eaf8033f08fb0b3eb00000000000000000ebf8033f08fb0b3eb00000000000000000ecf8033f08fb0b3eb00000000000000000edf8033f08fb0b3eb00000000000000000eef8033f08fb0b3eb00000000000000000eff8033f08fb0b3eb00000000000000000f0f8033f08fb0b3eb00000000000000000f1f8033f08fb0b3eb00000000000000000f2f8033f08fb0b3eb00000000000000000f3f8033f08fb0b3eb00000000000000000f4f8033f08fb0b3eb00000000000000000f5f8033f08fb0b3eb00000000000000000f6f8033f08fb0b3eb00000000000000000f7f8033f08fb0b3eb00000000000000000f8f8033f08fb0b3eb00000000000000000f9f8033f08fb0b3eb00000000000000000faf8033f08fb0b3eb00000000000000000fbf8033f08fb0b3eb00000000000000000fcf8033f08fb0b3eb00000000000000000fdf8033f08fb0b3eb00000000000000000fef8033f08fb0b3eb00000000000000000fff8033f08fb0b3eb0000000000000000100f8033f08fb0b3eb0000000000000000101f8033f08fb0b3eb0000000000000000102f8033f08fb0b3eb0000000000000000103f8033f08fb0b3eb0000000000000000104f8033f08fb0b3eb0000000000000000105f8033f08fb0b3eb0000000000000000106f8033f08fb0b3eb0000000000000000107f8033f08fb0b3eb0000000000000000108f8033f08fb0b3eb0000000000000000109f8033f08fb0b3eb000000000000000010af8033f08fb0b3eb000000000000000010bf8033f08fb0b3eb000000000000000010cf8033f08fb0b3eb000000000000000010df8033f08fb0b3eb000000000000000010ef8033f08fb0b3eb000000000000000010ff8033f08fb0b3eb0000000000000000110f8033f08fb0b3eb0000000000000000111f8033f08fb0b3eb0000000000000000112f8033f08fb0b3eb0000000000000000113f8033f08fb0b3eb0000000000000000114f8033f08fb0b3eb0000000000000000115f8033f08fb0b3eb0000000000000000116f8033f08fb0b3eb0000000000000000117f8033f08fb0b3eb0000000000000000118f8033f08fb0b3eb0000000000000000119f8033f08fb0b3eb000000000000000011af8033f08fb0b3eb000000000000000011bf8033f08fb0b3eb000000000000000011cf8033f08fb0b3eb000000000000000011df8033f08fb0b3eb000000000000000011ef8033f08fb0b3eb000000000000000011ff8033f08fb0b3eb0000000000000000120f8033f08fb0b3eb0000000000000000121f8033f08fb0b3eb0000000000000000122f8033f08fb0b3eb0000000000000000123f8033f08fb0b3eb0000000000000000124f8033f08fb0b3eb0000000000000000125f8033f08fb0b3eb0000000000000000126f8033f08fb0b3eb0000000000000000127f8033f08fb0b3eb0000000000000000128f8033f08fb0b3eb0000000000000000129f8033f08fb0b3eb000000000000000012af8033f08fb0b3eb000000000000000012bf802fc05656d70747900"
    static let nodeCompressedPlain = "00f8060904cb06fa0003f802f803416ca2f802fc04626c6f62fd000258000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fa000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f6061"
    static let nodeCompressedFrame = "02789cfbc1c6c9729aed1703f30fa61fcc8e398b7e30fd6149cac94ffacbc014c1c0c8c4ccc2cac6cec1c9c5cdc3cbc72f2028242c222a262e2129252d232b27afa0a8a4aca2aaa6aea1a9a5ada3aba76f6068646c626a666e6169656d636b67efe0e8e4ece2eae6eee1e9e5ede3ebe71f1018141c121a161e1119151d131b179f9098949c929a969e9199959d939b975f5058545c525a565e5159555d535b57dfd0d8d4dcd2dad6ded1d9d5ddd3dbd73f61e2a4c953a64e9b3e63e6acd973e6ce9bbf60e1a2c54b962e5bbe62e5aad56bd6ae5bbf61e3a6cd5bb66edbbe63e7aedd7bf6eedb7fe0e0a1c3478e1e3b7ee2e4a9d367ce9e3b7fe1e2a5cb57ae5ebb7ee3e6addb77eedebbffe0e1a3c74f9e3e7bfee2e5abd76fdebe7bffe1e3a7cf5fbe7efbfee3e7af51afd3d0eb006e1c12cc"
    static let clientPayloadLogin = "088784b4f73918012a38080e120b080210b8171884b483f5031a0330303022033030302a03302e3132003a074465736b746f704203302e3150005a02656e620255533202200060016801900107c00101880201c80201"
    static let clientPayloadRegistration = "18002a38080e120b080210b8171884b483f5031a0330303022033030302a03302e3132003a074465736b746f704203302e3150005a02656e6202555332022000600168019a01df010a04123456781201051a20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f22030000012a20202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f3240404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f3a10ed6c6a921d03d857ec78c153a7f7a0cf42370a0d73747570696420736f6369616c1206080010011800180520002a1a188050200130003801400148015001580160017001780198013c880200"
    static let deviceProps = "0a0d73747570696420736f6369616c1206080010011800180520002a1a188050200130003801400148015001580160017001780198013c"
    static let clientHello = "12220a20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    static let serverHello = "1aba010a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20123002030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30311a64030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263646566"
    static let clientFinish = "22fd010a300405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323312c80105060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcc"
    static let certChain = "0a760a32080910071a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202081e2cfaa062881e6fe890712400101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010112760a32080710001a20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2080e2cfaa062880e6fe8907124000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    static let advHMAC = "0a740a0e08631080e2cfaa061804200028001220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f1a40000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f1220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f1801"
    static let advSignedWithDevice = "0a0e08631080e2cfaa061804200028001220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f1a40000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f22406465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3"
    static let advSignedForServer = "0a0e08631080e2cfaa061804200028001a40000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f22406465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3"
    static let messageReply = "324d0a0761207265706c798a01410a0833454230414141411213313233343536373839303132333435406c69641a0e0a0c746865206f726967696e616c7a07313131406c69647a07323232406c6964"
    static let messageText = "0a0b68656c6c6f207468657265"
    static let messageReaction = "f202300a210a13313233343536373839303132333435406c696410011a0833454230424242421204f09f918d20fbd095ffbc31"
    static let messageReactionRemove = "f202300a2a0a1731323033363330303030303030303030303140672e757310001a04414243442207313131406c696412002005"
    static let messageInnerWithContext = "0a0b68656c6c6f2074686572659a02221a200000000000000000000000000000000000000000000000000000000000000000"
    static let messageDeviceSent = "fa01490a13313233343536373839303132333435406c696412320a0b68656c6c6f2074686572659a02221a2000000000000000000000000000000000000000000000000000000000000000009a02221a200000000000000000000000000000000000000000000000000000000000000000"
    static let messageLink = "32520a177365652068747470733a2f2f6578616d706c652e636f6d121368747470733a2f2f6578616d706c652e636f6d2a0f416e206578616d706c65207061676532074578616d706c65820107ffd87468756d62"
    static let messageEphemeralImage = "c202be010abb011ab8010a1a68747470733a2f2f6d6d672e77686174736170702e6e65742f78120a696d6167652f6a7065671a09612063617074696f6e2220010101010101010101010101010101010101010101010101010101010101010128b96030e003388005422002020202020202020202020202020202020202020202020202020202020202024a2003030303030303030303030303030303030303030303030303030303030303035a082f762f7436322f78820102ffd88a01040a025131"
    static let messageViewOnceVideo = "ba03270a254a231209766964656f2f6d7034280c3a04636c697048d00550800a6a082f762f766964656f"
    static let messageAudio = "421f1216617564696f2f6f67673b20636f646563733d6f70757320e70728073001"
    static let messageDocument = "aa03390a373a35120f6170706c69636174696f6e2f7064661a067265706f7274288010420a7265706f72742e706466a2010a746865207265706f7274"
    static let messageSticker = "d201112a0a696d6167652f776562703880046801"
    static let messageContact = "221c0a0c536f6d6520436f6e7461637482010b424547494e3a5643415244"
    static let messageLocation = "2a1d093333333333f340c01166666666666632401a09536f6d657768657265"
    static let messagePoll = "82041512064c756e63683f1a050a035965731a040a024e6f"
    static let messageUnknown = "9a02061a0400000000d202093207627574746f6e73"
    static let messageEdit = "d203330a31622f0a150a07313233406c696410011a083345423043434343100e720d0a0b656469746564207465787478e7d795ffbc31"
    static let messageRevoke = "62170a130a07313233406c69641a0833454230444444441000"
    static let messageHistoryNotification = "628b0110053286010a2004040404040404040404040404040404040404040404040404040404040404041080201a200505050505050505050505050505050505050505050505050505050505050505222006060606060606060606060606060606060606060606060606060606060606062a072f762f686973743003380242044f52494748285a06696e6c696e65"
    static let messageKeyShare = "626b10063a670a380a050a03000001122f0a2007070707070707070707070707070707070707070707070707070707070707071204080510021880d095ffbc310a2b0a050a0300000212220a200808080808080808080808080808080808080808080808080808080808080808"
    static let keyShareFingerprint = "08051002"
    static let messageLIDMigration = "622a1016ba01250a230a0e088784b4f73910f9beb7b088891c0a1108bfbfc3fb39108da0e187c3c8e0011801"
    static let messageSenderKey = "0a0b67726f75702068656c6c6f12200a1731323033363330303030303030303030303140672e7573120533736b646d"
    static let historySync = "080312b3020a13313233343536373839303132333435406c6964126a0a660a1d0a13313233343536373839303132333435406c696410001a044d53473112040a0268691890e5cfaa0620049a0105416c696365ca022e0a1d0a13313233343536373839303132333435406c696410011a044d5347311206e29da4efb88f20d08bb1ffbc311001123d0a3b0a1d0a13313233343536373839303132333435406c696410011a044d53473218ace4cfaa06c0018401d20106706172616d31d20106706172616d322890e5cfaa0630024880a30560f4e5cfaa066a00800100980101c00180e2cfaa06c80180e6fe8907b2020d416c696365204578616d706c65ba021a313535353132333435363740732e77686174736170702e6e6574d20213313233343536373839303132333435406c6964da0205616c696365128c010a1731323033363330303030303030303030303140672e757312490a470a260a1731323033363330303030303030303030303140672e75731a0247312207313131406c6964120e320c0a0a67726f7570207465787418e4e2cfaa062a07313131406c696438016a0a546573742047726f7570a2010b0a07313131406c69641001a201090a07323232406c6964280330373a230a1a313535353132333435363740732e77686174736170702e6e65741205416c6963657a310a1a313535353132333435363740732e77686174736170702e6e65741213313233343536373839303132333435406c6964"
    static let historySyncZlib = "789ce36016daccc4256c68646c626a666e6169006639e464a6086571a571c9629512609062f10d76371462e162cac89498f0f4fc2a360596598cac8e3999c9a9a798f470e96384ea637b3477c9fb1dfd0a17ba37fedf6328c02864cb658d5f8f91c49a27405b0e30b6305e62642b482c4acc3584318c34c02e3060f26858cc9af005c4ce6268606498c1c87880b1e111907b82b1e1d9bf4ef64d4cbc60172ab85624e616e4a4ee62923234353585daea50ac579e9158529c5850a097975a7289099b736e31b126828c10ea61e412373432303633364000438774bdd262214f2e772e359cd2524cee864aec868686e050e633e2e1e24a2fca2f2d502849ad2891780272af164cda82318b2b24b5b844c11da462112337174c46807111232717bb91911188a7c16c606ea5cc85c73b4290c8a932c4ab089b9701e6e39793"
    static let externalBlob = "0a20090909090909090909090909090909090909090909090909090909090909090912072f762f626c6f621a0168204d2a200a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a32200b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
    static let syncdSnapshot = "0a02082a127f0a220a200c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c12520a500d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d1a050a030000011a200e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e22050a03000001"
    static let syncdPatch = "0a02082b12730801126f0a220a200f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f12420a40101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101a050a030000021228080012240a220a2011111111111111111111111111111111111111111111111111111111111111111a740a20090909090909090909090909090909090909090909090909090909090909090912072f762f626c6f621a0168204d2a200a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a32200b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b222012121212121212121212121212121212121212121212121212121212121212122a20131313131313131313131313131313131313131313131313131313131313131332050a030000024003"
    static let syncdMutations = "0a730801126f0a220a200f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f12420a40101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101a050a03000002"
    static let syncContact = "0a285b22636f6e74616374222c22313535353132333435363740732e77686174736170702e6e6574225d12500880d095ffbc311a470a0d416c696365204578616d706c651205416c6963651a13313233343536373839303132333435406c69642a1a313535353132333435363740732e77686174736170702e6e65741a0200002002"
    static let syncMute = "0a125b226d757465222c22313233406c6964225d120f220d080110ffffffffffffffffff012002"
    static let syncMisc = "0a155b2261726368697665222c22313233406c6964225d121608052a0208018a01020801a201020800aa0100b201002003"
}
