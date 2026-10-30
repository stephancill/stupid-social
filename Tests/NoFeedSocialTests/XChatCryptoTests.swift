import CryptoKit
import Foundation
@testable import NoFeedSocialCore
import XCTest

/// Vectors from PyNaCl and from scripts/xchat-client.py, whose XChat crypto was validated against live
/// messages. All keys here are synthetic.
final class XChatCryptoTests: XCTestCase {
    private let key = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    private let nonce = Data(hex: "6465666768696a6b6c6d6e6f707172737475767778797a7b")

    private func plaintext(length: Int) -> Data {
        Data((0 ..< length).map { UInt8(($0 * 7 + length) % 256) })
    }

    /// libsodium's secretbox (MAC || ciphertext) across Poly1305 block boundaries.
    func testSecretBoxMatchesLibsodium() throws {
        let vectors: [(Int, String)] = [
            (0, "f49572d6194281e3c87fbb4e2106932c"),
            (1, "2c76eedb93589b714c2a8c573fa78b0e03"),
            (15, "3b964916d655ca163a5faf26ef8d0cb20daf84ed1184f7a9f7b376c854eed2"),
            (16, "cf5cf726fb6f46d37747ea98b22648a412ae87ec1685f4a8f8b275c953efd161"),
            (17, "cab303243b557675c4f2087d0e80cbd113a186ef1782f5abf9ad74ca52e8d062bf"),
            (31, "baadbafc1fa910d529b869aab85480f61d9fb4fd01f487b9e7a346f844fe2290b13ca5034f14f2db61c29748e96138"),
            (32, "d25ae3988b6f1a6c89b072ea2d244e79229eb7fc06f584b8e8a245f943ff2191ae3da6024815f1da6ec39449ee603b71"),
            (33, "cdd446b236e945e5b3aebc50ab65d59a2391b6ff07f285bbe99d44fa42f82092af32a7014912f0d96fdc954aef673a72a9"),
            (64, "821b15d88985995fa78d3c65a82a794542fed79c66d5a498c882a519a31f01b18e1d8662287591fa4ee3b4690e80db918848da2d7374d1b5ad49710f74685fec510730bdbe35839ecb2e85d93f596c9d"),
            (100, "46c26454b02ef3932acdfd49bd63423b66d2ebb0ba31407c2c5e89258f3b65d5ea71da4e1451b51eaa1f58b522a4ffb5ec24a6412f50f59189959df3988c7bc8752b6cd1c251e7baef12a905d3bd887967a07e54887b06dfe5ec758338bc6b1ec00c2fae1748c5c75e4853c69009133bfec2fb62"),
        ]
        for (length, box) in vectors {
            XCTAssertEqual(try SecretBox.seal(plaintext(length: length), nonce: nonce, key: key), Data(hex: box), "length \(length)")
            XCTAssertEqual(try SecretBox.open(Data(hex: box), nonce: nonce, key: key), plaintext(length: length), "length \(length)")
        }
        let long = try SecretBox.seal(plaintext(length: 1000), nonce: nonce, key: key)
        XCTAssertEqual(Data(SHA256.hash(data: long)), Data(hex: "483ff0ce06cc0f8cbf9f7c91c09c241d5d3e445b96410f014e42497e273547e6"))
    }

    func testSecretBoxRejectsTampering() throws {
        var sealed = try XChatCrypto.seal(Data("hello".utf8), key: key)
        sealed[sealed.count - 1] ^= 1
        XCTAssertThrowsError(try XChatCrypto.open(sealed, key: key))
    }

    func testSealOpensWithRandomNonce() throws {
        let message = Data("Test message".utf8)
        XCTAssertEqual(try XChatCrypto.open(XChatCrypto.seal(message, key: key), key: key), message)
    }

    func testUnwrapsConversationKey() throws {
        let wrapped = try XCTUnwrap(Data(base64Encoded: "BFiJPMZcxcDaRqFMWkKHjYdwA2I83O7GLLmpBp+iwC6kAmWrjKXuxkbT9M3r21XzHO7mbpR8/2nvOiJ0a+izlNQCFWXTzdHdumDqPVp5LG6kX541d4i2KCaeJFqPK9xKXn/mB4oIGvQJLuFZP/f4lzE="))
        let unwrapped = try XChatCrypto.unwrapConversationKey(wrapped, identityPrivateKey: Data(hex: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"))
        XCTAssertEqual(unwrapped, Data(hex: "c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7"))
    }

    func testFrankingTag() {
        let tag = XChatCrypto.frankingTag(
            plaintext: Data(hex: "0c00010c00010b0001000000026869000000"),
            nonce: Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            messageId: "8a7a1c0e-0000-4000-8000-000000000001",
            conversationId: "100:200",
        )
        XCTAssertEqual(tag, Data(hex: "7df6ef12af6a158f570e63c4d6cb2cffcbc94e71bbd1abbe07415b2c3844a371"))
    }

    func testVerifiesPythonSignatureAndSignsVerifiably() throws {
        let payload = "MessageCreateEvent,8a7a1c0e-0000-4000-8000-000000000001,100,100:200,1793136052618,AAAA"
        let publicKey = try XCTUnwrap(Data(base64Encoded: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE5kFJ8vpVVwBJvUJKDXHnRjNQqi60iaJUt5tJ8DtCtUMupO+atjE+lHFVLN4j0WhJ5BA8kHoftoDYwYOTDOxs/Q=="))
        let signature = try XCTUnwrap(Data(lenientBase64: "yplWAGsChcoQQ+kZ+Wi6iUhVL9dlnF+2SC4ap8XOYW1AxV5IUrepmnYYUzPLsr+RXS8a0nKXDwynKrXbzu70kQ"))
        XCTAssertTrue(XChatCrypto.isValidSignature(signature, payload: payload, signingPublicKeyDER: publicKey))
        XCTAssertFalse(XChatCrypto.isValidSignature(signature, payload: payload + "x", signingPublicKeyDER: publicKey))

        let privateKey = P256.Signing.PrivateKey()
        let own = try XChatCrypto.sign(payload, signingPrivateKey: privateKey.rawRepresentation)
        XCTAssertEqual(own.count, 64)
        XCTAssertTrue(XChatCrypto.isValidSignature(own, payload: payload, signingPublicKeyDER: privateKey.publicKey.derRepresentation))
    }

    func testThriftRoundTrip() throws {
        var inner = ThriftStruct()
        inner[1] = .string("hi")
        inner[2] = .structs([])
        inner[7] = .i32(1)
        var outer = ThriftStruct()
        outer[1] = .structure(inner)
        outer[6] = .i16(-2)
        outer[10] = .i64(2_115_195_109_255_905_280)
        outer[11] = .bool(true)
        let decoded = try ThriftCoder.decode(ThriftCoder.encode(outer))
        XCTAssertEqual(decoded, outer)
        XCTAssertEqual(decoded.structure(1)?.string(1), "hi")
        XCTAssertEqual(decoded.int(6), -2)
        XCTAssertEqual(decoded.int(10), 2_115_195_109_255_905_280)
    }

    /// Encrypted media: a libsodium secretstream (XChaCha20-Poly1305) in 1024-byte chunks, the last tagged final,
    /// as dm-core pushes it. Made with PyNaCl from a random key, 1100 bytes so the stream has two chunks.
    private let mediaKey = Data(hex: "38b0c0c70a91994be4fd6292c3fb34fca38c5baad56de5202d87af5cb25e7070")
    private let mediaBlob = Data(hex: [
        "38f7e70b757b7765384ea094fc6e73ddb4c97a9bd5b9ee3433720e4e1690d7f560077b5ca5b0a9362631763cf99c9557bef79b6866e50809782d55b8",
        "4812e6244a7babe8417f5bda7604632af6bf98c25d7ae9b2b6ad94de1459da1024c794ceeb10fb0ffecb5f6905c49ae6c4331d280dc06c9a4da57b4e",
        "8c50fbfcc6829ece322b7ba2fd2e7f77eb5543520f32b07538ba8b0becf6d029484f6b8a2006717597d66a55679bb353f2dce41d12f1d231414a9bc5",
        "8f1da0b48164a8922601ecc8f55002804202f669d8ed82fc17d9aa7e2f69ec9f2637bec88faeadf7e663b9b801472ccc25dd9ed367e7de10028057b3",
        "826a547d9366c0ac3e9fa2b560d9e22bc254ab3e13c057cc15a4f12bd60aadd7e718dd6415f71e2a1a62f04b629987d06ce3698421eee220edacedf7",
        "22dec92b3d636c6b47cd8c579b9c36f9fb6b7f25695002fa1cc8f0e69b1847057b07ac4f4ca40c766c852a456bc65af4d1e27f051881eb90f0c1767f",
        "ad727b44adb42d3e73bf01e79b2fafd4e130d8911ec27d9571f3d96a7015567087d6cc42d0314f42954954b4d481cddb2c54d2e8df9d84fa53464222",
        "1806027673a78121951f6b574ce4986637691922ac510246c5fae73916d7861f606bd92a14b7f078349e28784649dfe5b54c145fbb7db5d217d1978d",
        "744b562ce0cc10ab76ee298d9b68d10fbbdf9594ffb1b2a5212c91da262079cc0b69f9d926eebb690252b1da99f898c94a8ce8abe759883f026fbab2",
        "7938a5389f6f7d0bb17cabcdcf2f00656f653231880e3e468caff256396173ef3b984c6817222e1a8e3cbcb89e76f28fe49fadf483d68a0a09abf302",
        "1af28acb14a6b1893b29060b58d51c85d7846e4f5d45c4620888208b72639e18bf0cb37a0d178bb65addbfe13e8ae0ca9811062b30822e695b1914eb",
        "2da0ec50944835f0c90ef99d451c1a2edb8895a90615a46769bf8dffd32d2d181f29649cadc9f5d5277a6389c445c8042b1107aa5de7ba6cadaf67e1",
        "bf04cdda2ec9bf10c915974100a6c3a4c27f8a54de370ee37540c5a0442d15b82b02a7b25d1470b5e15f8718c681807e27a36ab05ae8460b9ae52cd4",
        "8788d6466abbb5348fcc6f5e44d18831c0ca2ce99dc37f15496f887a574972d559292d03900075d9cef41837f5f0f2b336acd935413b8cf088382e33",
        "9b5e1460049a7aa5a9958961eb39d2fb7cf275807231cac013473e6e64b2aeb253a51c83fdbed9034de0f516edbcb2def54bea9d7de29763a2054ed8",
        "16b1e721721a5895284837786beb1f3761f829207ad7b6c78038bfcc42aeab161252b9d7ab7fab394996a3919403aacc288677f0d725a7f0c96dca31",
        "2d3bf477e6de2cd82ef15e9155752302738d58ebe4b9baa2ea21e2980515a5ad4562d730c0eeb3a6f7b5b0fec25a80177249dd8d9bde88bb3334f808",
        "9fb7bf32d5500f5b17ea411bd8521b1f584fc974a7bc9eaa787b9df377b162e2d4be56dbad31a1bfca26d74b2d39de7fb86820c3506a28f0cd00b63f",
        "0e47508e08ce85c24230f0a8cd3facb3f0b8fb67056f472688a84f3c29736d6e02bab4700ea7b8775c0473698fbe7c51ba94291b9e4f610f0decaf43",
        "4961de7a6a582533dac986974ead5ab9119e",
    ].joined())
    private let mediaPlaintext = Data((0 ..< 1100).map { UInt8(($0 * 7 + 1100) % 256) })

    func testDecryptsMediaStream() throws {
        XCTAssertEqual(mediaBlob.count, 24 + 1024 + 17 + 76 + 17)
        XCTAssertEqual(try XChatCrypto.decryptMedia(mediaBlob, key: mediaKey), mediaPlaintext)
        XCTAssertEqual(Data(SHA256.hash(data: mediaPlaintext)), Data(hex: "24046e0bc9cdc7d1a46f54b1ae2c74db50454d799a5634f063c0a83a30577973"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("encrypted"), output = directory.appendingPathComponent("plain")
        try mediaBlob.write(to: input)
        let hash = try XChatCrypto.decryptMedia(from: input, to: output, key: mediaKey)
        XCTAssertEqual(try Data(contentsOf: output), mediaPlaintext)
        XCTAssertEqual(hash, Data(SHA256.hash(data: mediaPlaintext)))
    }

    func testMediaStreamRejectsTamperingAndTruncation() {
        var tampered = mediaBlob
        tampered[100] ^= 1
        XCTAssertThrowsError(try XChatCrypto.decryptMedia(tampered, key: mediaKey))
        // Without its final chunk the stream ends on a message tag.
        XCTAssertThrowsError(try XChatCrypto.decryptMedia(mediaBlob.prefix(24 + 1024 + 17), key: mediaKey))
        var wrongKey = mediaKey
        wrongKey[0] ^= 1
        XCTAssertThrowsError(try XChatCrypto.decryptMedia(mediaBlob, key: wrongKey))
    }

    func testMediaURLRoundTrip() throws {
        let reference = XChatMediaReference(conversationId: "100:200", hashKey: "AbC123xYz0", keyVersion: "1792015370411", fileExtension: "mp4")
        let url = try XCTUnwrap(XChatMediaURL.make(reference))
        XCTAssertEqual(XChatMediaURL.parse(url), reference)
        XCTAssertEqual(XChatMediaURL.downloadURL(reference).absoluteString, "https://ton.x.com/i/ton/data/xchat_media/100:200/AbC123xYz0")
    }

    /// A message sent without encryption has no key version (101) and carries the plain `MessageEntryHolder`
    /// (observed 2026-10-29), so it reads without any conversation key.
    func testUnencryptedMessageReadsWithoutAConversationKey() async throws {
        var message = ThriftStruct()
        message[1] = .string("Sent without encryption")
        var entry = ThriftStruct()
        entry[1] = .structure(message)
        var holder = ThriftStruct()
        holder[1] = .structure(entry)
        var create = ThriftStruct()
        create[100] = .binary(ThriftCoder.encode(holder))
        create[102] = .bool(true)
        create[109] = .bool(true)
        var detail = ThriftStruct()
        detail[1] = .structure(create)
        var event = ThriftStruct()
        event[1] = .string("2115726270839333051")
        event[3] = .string("1")
        event[4] = .string("1:2")
        event[7] = .structure(detail)

        let suite = "XChatCryptoTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let client = XChatClient(credentialStore: KeychainCredentialStore(service: suite, fallbackStore: defaults, prefersSynchronizable: false, allowsInsecureFallback: true))
        let decoded = try await client.decrypt(XChatEvent(event))
        guard case let .message(contents) = decoded else { return XCTFail("expected a message, got \(String(describing: decoded))") }
        XCTAssertEqual(contents.text, "Sent without encryption")
    }
}
