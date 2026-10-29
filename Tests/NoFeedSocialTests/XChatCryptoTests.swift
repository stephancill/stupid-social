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
