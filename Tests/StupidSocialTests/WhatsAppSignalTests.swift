import CryptoKit
import Foundation
@testable import StupidSocialCore
import XCTest

/// Vectors from scripts/whatsapp-client.py, whose Signal implementation was validated against live
/// WhatsApp traffic. Swift output with seeded randomness is pinned below after the probe decrypted it
/// (Swift Bob's reply, Swift Alice's prekey message and the Swift sender key messages), and the probe's
/// answer to Swift Bob's reply is decrypted here. All keys are synthetic.
final class WhatsAppSignalTests: XCTestCase {
    private func key(_ hex: String) throws -> WhatsAppKeyPair {
        try WhatsAppKeyPair(privateKey: Data(hex: hex))
    }

    private func store(identity: WhatsAppKeyPair, registrationId: UInt32, signed: WhatsAppKeyPair = .generate(), signature: Data = Data(), seed: String? = nil) -> WhatsAppSignalStore {
        var store = WhatsAppSignalStore(identity: identity, registrationId: registrationId, signedPreKey: WhatsAppSignedPreKey(id: 1, keyPair: signed, signature: signature))
        if let seed {
            let random = SeededRandom(seed)
            store.random = { random.bytes($0) }
        }
        return store
    }

    private func probeBob(seed: String? = nil) throws -> WhatsAppSignalStore {
        try store(identity: key(Vectors.sessionBobIdentity), registrationId: 4321, signed: key(Vectors.sessionBobSigned), signature: Data(hex: Vectors.sessionBobSignature), seed: seed)
    }

    private func probeBobBundle() throws -> WhatsAppPreKeyBundle {
        try WhatsAppPreKeyBundle(
            registrationId: 4321,
            identity: key(Vectors.sessionBobIdentity).publicKey,
            signedPreKeyId: 1,
            signedPreKey: key(Vectors.sessionBobSigned).publicKey,
            signature: Data(hex: Vectors.sessionBobSignature),
            preKeyId: 7,
            preKey: key(Vectors.sessionBobOneTime).publicKey,
        )
    }

    // MARK: Primitives

    func testXEdDSAMatchesProbe() throws {
        let privateKey = Data(hex: Vectors.xeddsaPrivate)
        let publicKey = try WhatsAppKeyPair(privateKey: privateKey).publicKey
        XCTAssertEqual(publicKey, Data(hex: Vectors.xeddsaPublic))
        for (message, signature) in Vectors.xeddsaSignatures {
            let signed = WhatsAppXEdDSA.sign(privateKey: privateKey, message: Data(hex: message), random: Data(hex: Vectors.xeddsaRandom))
            XCTAssertEqual(signed, Data(hex: signature), "message \(message.count / 2) bytes")
            XCTAssertTrue(WhatsAppXEdDSA.verify(publicKey: publicKey, message: Data(hex: message), signature: Data(hex: signature)))
            XCTAssertFalse(WhatsAppXEdDSA.verify(publicKey: publicKey, message: Data(hex: message) + [0], signature: Data(hex: signature)))
            var tampered = Data(hex: signature)
            tampered[10] ^= 1
            XCTAssertFalse(WhatsAppXEdDSA.verify(publicKey: publicKey, message: Data(hex: message), signature: tampered))
        }
    }

    func testXEdDSARoundTripsWithRandomKeys() {
        for _ in 0 ..< 20 {
            let pair = WhatsAppKeyPair.generate()
            let message = WhatsAppCipher.randomBytes(Int.random(in: 0 ..< 100))
            let signature = pair.sign(message)
            XCTAssertTrue(WhatsAppXEdDSA.verify(publicKey: pair.publicKey, message: message, signature: signature))
            XCTAssertFalse(WhatsAppXEdDSA.verify(publicKey: WhatsAppKeyPair.generate().publicKey, message: message, signature: signature))
        }
    }

    func testFieldEncodingIsCanonical() {
        // p + 5 decodes to 5; p - 1 stays.
        var pPlus5 = [UInt8](repeating: 0xFF, count: 32)
        pPlus5[0] = 0xF2
        pPlus5[31] = 0x7F
        XCTAssertEqual(Ed25519Field(bytes: pPlus5).bytes(), [5] + [UInt8](repeating: 0, count: 31))
        var pMinus1 = pPlus5
        pMinus1[0] = 0xEC
        XCTAssertEqual(Ed25519Field(bytes: pMinus1).bytes(), pMinus1)
        let x = Ed25519Field(bytes: [UInt8](WhatsAppCipher.randomBytes(32)))
        XCTAssertEqual((x * x.inverted()).bytes(), Ed25519Field.one.bytes())
    }

    func testX25519AndKDFsMatchProbe() throws {
        XCTAssertEqual(try key(Vectors.x25519Private).agree(with: Data(hex: Vectors.x25519Public)), Data(hex: Vectors.x25519Shared))
        let ikm = Data(hex: Vectors.hkdfIkm), salt = Data(hex: Vectors.hkdfSalt)
        XCTAssertEqual(WhatsAppCipher.hkdf(ikm, length: 80, info: Data("WhisperMessageKeys".utf8)), Data(hex: Vectors.hkdfNoSalt80))
        XCTAssertEqual(WhatsAppCipher.hkdf(ikm, length: 64, salt: salt, info: Data("WhisperRatchet".utf8)), Data(hex: Vectors.hkdfSalt64))
        XCTAssertEqual(WhatsAppCipher.hkdf(Data(), length: 64, salt: salt), Data(hex: Vectors.hkdfEmptyKey64))

        let keys = WhatsAppSignalStore.messageKeys(chainKey: Data(hex: Vectors.chainChainKey), index: 0)
        XCTAssertEqual(keys.cipherKey, Data(hex: Vectors.chainCipherKey))
        XCTAssertEqual(keys.macKey, Data(hex: Vectors.chainMacKey))
        XCTAssertEqual(keys.iv, Data(hex: Vectors.chainIv))
        XCTAssertEqual(WhatsAppSignalStore.chainNext(Data(hex: Vectors.chainChainKey)), Data(hex: Vectors.chainNext))
        let ourRatchet = try key(Self.clamped("our ratchet")), theirRatchet = try key(Self.clamped("their ratchet")).publicKey
        let (root, chain) = try WhatsAppSignalStore.rootCreateChain(rootKey: Data(hex: Vectors.chainRootKey), theirRatchet: theirRatchet, ourRatchet: ourRatchet)
        XCTAssertEqual(root, Data(hex: Vectors.chainRootNext))
        XCTAssertEqual(chain, Data(hex: Vectors.chainChainNext))
    }

    func testCiphersMatchProbe() throws {
        let key = Data(hex: Vectors.cipherKey), iv = Data(hex: Vectors.cipherIv), plaintext = Data(hex: Vectors.cipherPlaintext)
        XCTAssertEqual(try WhatsAppCipher.aesCBCEncrypt(key: key, iv: iv, plaintext), Data(hex: Vectors.cipherCbc))
        XCTAssertEqual(try WhatsAppCipher.aesCBCDecrypt(key: key, iv: iv, Data(hex: Vectors.cipherCbc)), plaintext)
        XCTAssertEqual(try WhatsAppCipher.aesCTR(key: key, iv: iv, plaintext), Data(hex: Vectors.cipherCtr))
        XCTAssertEqual(try WhatsAppCipher.aesCTR(key: key, iv: iv, Data(hex: Vectors.cipherCtr)), plaintext)
        let header = Data("header".utf8)
        XCTAssertEqual(try WhatsAppCipher.aesGCMSeal(key: key, nonce: iv.prefix(12), plaintext, authenticating: header), Data(hex: Vectors.cipherGcm))
        XCTAssertEqual(try WhatsAppCipher.aesGCMOpen(key: key, nonce: iv.prefix(12), Data(hex: Vectors.cipherGcm), authenticating: header), plaintext)
        XCTAssertThrowsError(try WhatsAppCipher.aesGCMOpen(key: key, nonce: iv.prefix(12), Data(hex: Vectors.cipherGcm))) {
            XCTAssertEqual($0 as? WhatsAppCipherError, .authenticationFailed)
        }
        XCTAssertEqual(WhatsAppCipher.pbkdf2SHA256(password: Data("ABCD1234".utf8), salt: Data(hex: Vectors.hkdfSalt), iterations: 2 << 16, length: 32), Data(hex: Vectors.cipherPbkdf2))
        XCTAssertEqual(WhatsAppCipher.hmacSHA512(key: key, plaintext), Data(hex: Vectors.cipherHmac512))
        var badPadding = try WhatsAppCipher.aesCBCEncrypt(key: key, iv: iv, plaintext)
        badPadding[badPadding.count - 1] ^= 1
        XCTAssertThrowsError(try WhatsAppCipher.aesCBCDecrypt(key: key, iv: iv, badPadding))
    }

    // MARK: Sessions against the probe

    /// The probe's Alice sends two prekey messages; Swift Bob decrypts them out of order and replies, the
    /// probe decrypted that reply and answered with a ratchet step, which Swift Bob decrypts.
    func testSessionWithProbe() throws {
        var bob = try probeBob(seed: "swift bob")
        let oneTime = try key(Vectors.sessionBobOneTime)
        var lookups: [UInt32] = []
        let second = try bob.decryptPreKeyMessage(address: "alice.0", Data(hex: Vectors.sessionSecond)) { id in
            lookups.append(id)
            return id == 7 ? oneTime : nil
        }
        XCTAssertEqual(second, WhatsAppPreKeyDecryption(plaintext: Data("second".utf8), usedPreKeyId: 7))
        let first = try bob.decryptPreKeyMessage(address: "alice.0", Data(hex: Vectors.sessionFirst)) { _ in nil }
        XCTAssertEqual(first, WhatsAppPreKeyDecryption(plaintext: Data("hello bob".utf8), usedPreKeyId: nil), "the session for this base key is reused")
        XCTAssertEqual(lookups, [7])
        XCTAssertEqual(bob.state.identities["alice.0"], try key(Vectors.sessionAliceIdentity).publicKey)

        let reply = try bob.encrypt(address: "alice.0", Data("hello alice".utf8))
        XCTAssertEqual(reply.type, .msg)
        XCTAssertEqual(reply.data, Data(hex: SwiftOutputs.bobReply))
        XCTAssertEqual(try bob.decryptMessage(address: "alice.0", Data(hex: SwiftOutputs.probeThird)), Data("third".utf8))
        XCTAssertThrowsError(try bob.decryptMessage(address: "alice.0", Data(hex: SwiftOutputs.probeThird))) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .oldCounter(counter: 0, current: 1))
        }
    }

    /// Swift Alice builds a session from the probe Bob's bundle; the probe decrypted this prekey message.
    func testBuildSessionForProbe() throws {
        var alice = try store(identity: key(Vectors.sessionAliceIdentity), registrationId: 1234, seed: "swift alice")
        try alice.buildSession(address: "bob.0", bundle: probeBobBundle())
        XCTAssertTrue(alice.hasSession(address: "bob.0"))
        let message = try alice.encrypt(address: "bob.0", Data("from swift alice".utf8))
        XCTAssertEqual(message.type, .pkmsg)
        XCTAssertEqual(message.data, Data(hex: SwiftOutputs.swiftAlice))

        var bundle = try probeBobBundle()
        bundle.signature[5] ^= 1
        XCTAssertThrowsError(try alice.buildSession(address: "bob.1", bundle: bundle)) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .invalidSignedPreKeySignature)
        }
    }

    func testDecryptsProbeGroupMessages() throws {
        var bob = try probeBob()
        XCTAssertThrowsError(try bob.decryptGroupMessage(group: "123@g.us", address: "alice.0", Data(hex: Vectors.groupMessages[0]))) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .noSenderKey)
        }
        try bob.processSenderKeyDistribution(group: "123@g.us", address: "alice.0", Data(hex: Vectors.groupDistribution))
        for index in [0, 2, 1, 3] {
            XCTAssertEqual(try bob.decryptGroupMessage(group: "123@g.us", address: "alice.0", Data(hex: Vectors.groupMessages[index])), Data("group \(index)".utf8))
        }
        XCTAssertThrowsError(try bob.decryptGroupMessage(group: "123@g.us", address: "alice.0", Data(hex: Vectors.groupMessages[1]))) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .oldCounter(counter: 1, current: 4))
        }
        var tampered = Data(hex: Vectors.groupMessages[3])
        tampered[tampered.count - 70] ^= 1
        XCTAssertThrowsError(try bob.decryptGroupMessage(group: "123@g.us", address: "alice.0", tampered)) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .badSenderKeySignature)
        }
        tampered = Data(hex: Vectors.groupMessages[3])
        tampered[8] ^= 0x40
        XCTAssertThrowsError(try bob.decryptGroupMessage(group: "123@g.us", address: "alice.0", tampered)) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .malformedMessage)
        }
    }

    /// Swift's sender key, which the probe decrypted, round-trips through Swift too.
    func testGroupSendingWithProbe() throws {
        var bob = try probeBob(seed: "swift group")
        let distribution = bob.senderKeyDistribution(group: "123@g.us", ownAddress: "bob.0")
        XCTAssertEqual(distribution, Data(hex: SwiftOutputs.groupDistribution))
        XCTAssertEqual(try ProtoMessage(distribution.dropFirst()).uint32(1).map { $0 < 1 << 31 }, true)
        let messages = try ["group from swift 0", "group from swift 1"].map {
            try bob.encryptGroupMessage(group: "123@g.us", ownAddress: "bob.0", Data($0.utf8))
        }
        XCTAssertEqual(messages, SwiftOutputs.groupMessages.map { Data(hex: $0) })
        let current = try ProtoMessage(bob.senderKeyDistribution(group: "123@g.us", ownAddress: "bob.0").dropFirst())
        XCTAssertEqual(current.uint32(1), try ProtoMessage(distribution.dropFirst()).uint32(1), "the key is reused")
        XCTAssertEqual(current.uint32(2), 2)

        var alice = try store(identity: key(Vectors.sessionAliceIdentity), registrationId: 1234)
        try alice.processSenderKeyDistribution(group: "123@g.us", address: "bob.0", distribution)
        XCTAssertEqual(try alice.decryptGroupMessage(group: "123@g.us", address: "bob.0", messages[1]), Data("group from swift 1".utf8))
        XCTAssertEqual(try alice.decryptGroupMessage(group: "123@g.us", address: "bob.0", messages[0]), Data("group from swift 0".utf8))
        XCTAssertThrowsError(try alice.encryptGroupMessage(group: "123@g.us", ownAddress: "bob.0", Data())) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .noSenderKey, "a received sender key can't sign")
        }
    }

    // MARK: Round trips

    /// scripts/whatsapp-client.py signal_selftest, plus out-of-order delivery, duplicates and persistence.
    func testSessionRoundTrip() throws {
        let bobIdentity = WhatsAppKeyPair.generate(), bobSigned = WhatsAppKeyPair.generate(), bobOneTime = WhatsAppKeyPair.generate()
        var alice = store(identity: .generate(), registrationId: 1)
        var bob = store(identity: bobIdentity, registrationId: 2, signed: bobSigned, signature: bobIdentity.sign(WhatsAppSignalStore.djb(bobSigned.publicKey)))
        try alice.buildSession(address: "bob.0", bundle: WhatsAppPreKeyBundle(
            registrationId: 2, identity: bobIdentity.publicKey, signedPreKeyId: 1, signedPreKey: bobSigned.publicKey,
            signature: bob.signedPreKey.signature, preKeyId: 7, preKey: bobOneTime.publicKey,
        ))
        let first = try alice.encrypt(address: "bob.0", Data("hello bob".utf8))
        XCTAssertEqual(first.type, .pkmsg)
        XCTAssertFalse(bob.hasSession(address: "alice.0"))
        let peek = try bob.decryptPreKeyMessage(address: "alice.0", first.data, keepState: false) { $0 == 7 ? bobOneTime : nil }
        XCTAssertEqual(peek.plaintext, Data("hello bob".utf8))
        XCTAssertFalse(bob.hasSession(address: "alice.0"), "keepState false stores nothing")
        let decrypted = try bob.decryptPreKeyMessage(address: "alice.0", first.data) { $0 == 7 ? bobOneTime : nil }
        XCTAssertEqual(decrypted.usedPreKeyId, 7)

        let reply = try bob.encrypt(address: "alice.0", Data("hello alice".utf8))
        XCTAssertEqual(reply.type, .msg)
        XCTAssertEqual(try alice.decryptMessage(address: "bob.0", reply.data), Data("hello alice".utf8))
        let again = try alice.encrypt(address: "bob.0", Data("again".utf8))
        XCTAssertEqual(again.type, .msg, "the pending prekey clears once Bob has answered")
        let outOfOrder = try alice.encrypt(address: "bob.0", Data("out of order".utf8))
        XCTAssertEqual(try bob.decryptMessage(address: "alice.0", outOfOrder.data), Data("out of order".utf8))
        XCTAssertEqual(try bob.decryptMessage(address: "alice.0", again.data), Data("again".utf8), "skipped message keys are kept")
        XCTAssertThrowsError(try bob.decryptMessage(address: "alice.0", again.data)) {
            guard case .oldCounter = $0 as? WhatsAppSignalError else { return XCTFail("\($0)") }
        }

        // Several ratchet steps each way, with state persisted between them.
        for round in 0 ..< 4 {
            bob.state = try JSONDecoder().decode(WhatsAppSignalState.self, from: JSONEncoder().encode(bob.state))
            let messages = try (0 ..< 3).map { try bob.encrypt(address: "alice.0", Data("bob \(round) \($0)".utf8)) }
            for (index, message) in messages.enumerated().reversed() {
                XCTAssertEqual(try alice.decryptMessage(address: "bob.0", message.data), Data("bob \(round) \(index)".utf8))
            }
            let answer = try alice.encrypt(address: "bob.0", Data("alice \(round)".utf8))
            XCTAssertEqual(try bob.decryptMessage(address: "alice.0", answer.data), Data("alice \(round)".utf8))
        }

        var tampered = try alice.encrypt(address: "bob.0", Data("tampered".utf8)).data
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try bob.decryptMessage(address: "alice.0", tampered)) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .noValidSession(.badMAC))
        }
        XCTAssertThrowsError(try bob.decryptMessage(address: "carol.0", reply.data)) {
            XCTAssertEqual($0 as? WhatsAppSignalError, .noSession)
        }
    }

    /// A rebuilt session archives the old one, which can still decrypt messages already in flight.
    func testArchivedSessionStillDecrypts() throws {
        let bobIdentity = WhatsAppKeyPair.generate(), bobSigned = WhatsAppKeyPair.generate()
        var alice = store(identity: .generate(), registrationId: 1)
        var bob = store(identity: bobIdentity, registrationId: 2, signed: bobSigned)
        let bundle = WhatsAppPreKeyBundle(
            registrationId: 2, identity: bobIdentity.publicKey, signedPreKeyId: 1, signedPreKey: bobSigned.publicKey,
            signature: bobIdentity.sign(WhatsAppSignalStore.djb(bobSigned.publicKey)),
        )
        try alice.buildSession(address: "bob.0", bundle: bundle)
        let old = try alice.encrypt(address: "bob.0", Data("old".utf8))
        try alice.buildSession(address: "bob.0", bundle: bundle)
        let new = try alice.encrypt(address: "bob.0", Data("new".utf8))
        XCTAssertEqual(alice.state.sessions["bob.0"]?.previous.count, 1)
        XCTAssertNil(try bob.decryptPreKeyMessage(address: "alice.0", new.data) { _ in nil }.usedPreKeyId)
        XCTAssertEqual(try bob.decryptPreKeyMessage(address: "alice.0", old.data) { _ in nil }.plaintext, Data("old".utf8))
        let reply = try bob.encrypt(address: "alice.0", Data("reply".utf8))
        XCTAssertEqual(try alice.decryptMessage(address: "bob.0", reply.data), Data("reply".utf8), "the archived state is promoted")
    }

    func testIdentityChangeReplacesSession() throws {
        let bobIdentity = WhatsAppKeyPair.generate(), bobSigned = WhatsAppKeyPair.generate()
        var bob = store(identity: bobIdentity, registrationId: 2, signed: bobSigned)
        let bundle = WhatsAppPreKeyBundle(
            registrationId: 2, identity: bobIdentity.publicKey, signedPreKeyId: 1, signedPreKey: bobSigned.publicKey,
            signature: bobIdentity.sign(WhatsAppSignalStore.djb(bobSigned.publicKey)),
        )
        for text in ["first device", "reinstalled"] {
            var alice = store(identity: .generate(), registrationId: 1)
            try alice.buildSession(address: "bob.0", bundle: bundle)
            let message = try alice.encrypt(address: "bob.0", Data(text.utf8))
            XCTAssertEqual(try bob.decryptPreKeyMessage(address: "alice.0", message.data) { _ in nil }.plaintext, Data(text.utf8))
            XCTAssertEqual(bob.state.identities["alice.0"], alice.identity.publicKey)
        }
        XCTAssertEqual(bob.state.sessions["alice.0"]?.previous.count, 0, "the old identity's session is dropped")
    }

    func testSenderKeyRecordKeepsFiveStates() throws {
        var bob = store(identity: .generate(), registrationId: 2)
        var senders: [WhatsAppSignalStore] = []
        for index in 0 ..< 6 {
            var sender = store(identity: .generate(), registrationId: UInt32(index))
            let distribution = sender.senderKeyDistribution(group: "g", ownAddress: "alice.0")
            try bob.processSenderKeyDistribution(group: "g", address: "alice.0", distribution)
            senders.append(sender)
        }
        XCTAssertEqual(bob.state.senderKeys["g|alice.0"]?.count, 5)
        let latest = try senders[5].encryptGroupMessage(group: "g", ownAddress: "alice.0", Data("latest".utf8))
        XCTAssertEqual(try bob.decryptGroupMessage(group: "g", address: "alice.0", latest), Data("latest".utf8))
        let dropped = try senders[0].encryptGroupMessage(group: "g", ownAddress: "alice.0", Data("dropped".utf8))
        XCTAssertThrowsError(try bob.decryptGroupMessage(group: "g", address: "alice.0", dropped)) {
            guard case .noSenderKeyState = $0 as? WhatsAppSignalError else { return XCTFail("\($0)") }
        }
    }

    func testMessagePadding() throws {
        for _ in 0 ..< 50 {
            let plaintext = WhatsAppCipher.randomBytes(Int.random(in: 0 ..< 40))
            let padded = WhatsAppMessagePadding.pad(plaintext)
            XCTAssertTrue((1 ... 15).contains(padded.count - plaintext.count))
            XCTAssertEqual(try WhatsAppMessagePadding.unpad(padded, version: 2), plaintext)
        }
        XCTAssertEqual(try WhatsAppMessagePadding.unpad(Data([1, 2, 3]), version: 3), Data([1, 2, 3]))
        XCTAssertThrowsError(try WhatsAppMessagePadding.unpad(Data([1, 2, 3]), version: 2))
        XCTAssertThrowsError(try WhatsAppMessagePadding.unpad(Data(), version: 2))
        XCTAssertThrowsError(try WhatsAppMessagePadding.unpad(Data([0]), version: 2))
    }

    /// Every group message is verified; this is a rough bound that also holds in debug builds.
    func testSignaturePerformance() {
        let pair = WhatsAppKeyPair.generate()
        let message = WhatsAppCipher.randomBytes(200)
        let signature = pair.sign(message)
        let verifies = 200
        var start = Date()
        for _ in 0 ..< verifies {
            XCTAssertTrue(WhatsAppXEdDSA.verify(publicKey: pair.publicKey, message: message, signature: signature))
        }
        let verify = Date().timeIntervalSince(start) / Double(verifies)
        start = Date()
        for _ in 0 ..< 10 {
            _ = pair.sign(message)
        }
        let sign = Date().timeIntervalSince(start) / 10
        print(String(format: "XEdDSA verify %.3f ms, sign %.3f ms", verify * 1000, sign * 1000))
        XCTAssertLessThan(verify, 0.01)
        XCTAssertLessThan(sign, 0.2)
    }

    private static func clamped(_ label: String) -> String {
        var bytes = [UInt8](SHA512.hash(data: Data(label.utf8))).prefix(32).map(\.self)
        bytes[0] &= 248
        bytes[31] &= 127
        bytes[31] |= 64
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic bytes: SHA-256(label || big-endian counter) blocks.
private final class SeededRandom: @unchecked Sendable {
    private let label: Data
    private var counter: UInt32 = 0
    private let lock = NSLock()

    init(_ label: String) {
        self.label = Data(label.utf8)
    }

    func bytes(_ count: Int) -> Data {
        lock.withLock {
            var output = Data()
            while output.count < count {
                output += SHA256.hash(data: label + withUnsafeBytes(of: counter.bigEndian) { Data($0) })
                counter += 1
            }
            return output.prefix(count)
        }
    }
}

/// Swift output with seeded randomness, each decrypted by the probe; `probeThird` is the probe's answer.
private enum SwiftOutputs {
    static let bobReply = "330a210597ffc5ae12021bea3ce743fca55574d8cdfa528d973a9977ec535265626e6b06100018002210e074569ccac9ed6959fd6831e2d265023875d9800053a5db"
    static let probeThird = "330a2105435119c71c36fab5fa2c724a1fa821fac765a665be52347597c60f0bc3ef2914100018012210487c7ca880d4e59169a7c22be837dec6c210179b9a199466"
    static let swiftAlice = "3308071221052dad21109018e8c838c7803e045540941fcec52da832405bf75eb48f2414f21c1a210562be5688c316a57636805cfc906cb1306d928c50aa36f33ef3bc6e5ded1375722252330a2105fd65c78c0577a96d2b53655b0b3047498776249d850bc16992e19ea6fe67a123100018002220350befbfad0935cb33999271188bee2086996a4ad2246bbdd9d6d07dfcf95164e43abbb79ede70a528d2093001"
    static let groupDistribution = "3308dad4c0db0710001a202835204fd3c3f4239e965012b902ef81b3e9899014965f4686424ae0c9bb6970222105806469124fd8c122000f664df35eef814d97b6c72816622426e522e6ed814220"
    static let groupMessages = [
        "3308dad4c0db0710001a20b0747e9245c57a952ff910ff188dc811ff262420abcc72cf87fc46ba7a1d01b72c33cb4f6bd6cac2f248df6125d1bd4a66b4a4e1b3e852066a1e71d478ec1688c258542546e20717a58cdb0ce5ebb0b6fc5c997a6717c9ac4c955262957a9784",
        "3308dad4c0db0710011a2072ee8f3c604cd7c30e29e50c7cffc218793740a345a417951eb5ca85eec94428d293d87a10635c5fc6320b32e374eaa515b9ea3319ac2c3ea197e134a961bae6bcdab7a9a923c728037400c7f25c0a3dec952fdfb243fe01fed34fd785e1828b",
    ]
}

/// Generated by the probe (scripts/whatsapp-client.py) from fixed keys and randomness.
private enum Vectors {
    static let xeddsaPrivate = "7cc1dbbc642b4baf1a3db8b5a80615e3b6e1e6191dce71e5bb3fc50f86178057"
    static let xeddsaPublic = "2c0234556d01c9c80572a77ee4da9dc0545782bcae8b72e6ec62d255d52d0506"
    static let xeddsaRandom = "a01dd2bfc73ee281059a6293241e8f1b5262c684190905c0e519ba598be134888bd2cfb94aef18d940cda6eaa6e4d6d211a4f606cd32a441eda2adfeda6996c6"
    static let xeddsaSignatures: [(message: String, signature: String)] = [
        ("", "14fb76540b0098bdfe5edc3d62f7173e60063179b0b6d9d47ea236d7efe64c8fffc921e92ae9bc2f597c7c7656d54cc3b7e284c1d822d8fb18219acc87720b8b"),
        ("73747570696420736f6369616c", "33c1bcd9edd582f6f204e558306ff3fbfa652a5c76a9967dce3d87981e26cfb9cef060f954b939bdd9fb06883464054ef38ab20645686da72079d944b26a2a88"),
        ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7", "181dcb58c4cc3980254a913020e674f04836b6ca703eabc69ddae4d12a5f99d13d14c0d68abe45806e5d211adadb033c8e947c6876605693368471b6478f118e"),
    ]
    static let x25519Private = "28bd0d0bc93b460d940f2126f40bdf6c3a788c7a86eefaedc5de6bc9e702465f"
    static let x25519Public = "6229a228d5238ff510c56e8a51b559afa062eee96c6d670ba521045ea7fdd34a"
    static let x25519Shared = "6cf47879094a52e63232f99936acf781b42d787da76c2968b52ac68aa35f6421"
    static let hkdfIkm = "084aa0f97ab8d2db415bc9c7d98f57c700f57bf408acb8a1d2129f0151c1529e"
    static let hkdfSalt = "2e3fce77cf8c4c7478a96d207c1c39715892cac84a18cbec9b634f4bc22b390b"
    static let hkdfNoSalt80 = "f17242d801611f143fcdaf3de9808c8e7cb8bffbc873bb22ee87e008ba3b432cfc4592d14a4c491c611c442ff4cf4d17f13ad64e01cb4b7a7669c36d107291f76f6e9c34195f8408b086973cc8c68e86"
    static let hkdfSalt64 = "6fb78523895fb493b5926989262fe9206bbae51d9716ea5ab00077e71a4a1ffa42c4d91c3bc8f876941461d25d5e2bbaddf721120795dae9e5904d28375e0d58"
    static let hkdfEmptyKey64 = "085aee69904c03b65d0d0e5b26b11ada42c57415dc3b80d13b0593ba08aa4a0b258ebd8cd0c98dd184f919188201e17aee8d5dacaf688825e440ca86391ff042"
    static let chainChainKey = "aebcbffc34d70c09733f2946744a34f5a3829413761204758b9772b87d12a436"
    static let chainCipherKey = "dc21e224bfe035ec24483539a02ec300e710bdbce562f1ec4577158dabf01ea9"
    static let chainMacKey = "1f81c134a743ab6705ce8dac55699c41fb77814aca76067e3c23a712886d1c24"
    static let chainIv = "c5d90956e8b38e88a8e8041b0c72328e"
    static let chainNext = "1ded27054715f0c0f63a4fb480c9e642edf3e7ebd548a5ba55f55ad5f1590860"
    static let chainRootKey = "99adc231b045331e514a516b4b7680f588e3823213abe901738bc3ad67b2f6fc"
    static let chainRootNext = "ed8ed562997cdff2529b12e9a8207348b18ec96cd6d8646bc762175c1fdfafcc"
    static let chainChainNext = "9f49e411f5901b353de6f4f5081c50352cbc28eef8e7517f81d3d46760b4ac32"
    static let cipherKey = "fafef3149f03ae1438ce3a12611e8c69507ba68a0ad4c686d539fd4b4c331e7d"
    static let cipherIv = "24ad3a32c3444067dbfd88b7a8d4e90a"
    static let cipherPlaintext = "73747570696420736f6369616c2063697068657220746573742c206c6f6e676572207468616e206f6e6520626c6f636b"
    static let cipherCbc = "566fc353e65bcb8a32c500929c0b275477b3d9fac3d99626025b090019523600dfd1989bdc42b2bea7ae9e34b59d548c957a023a90ff611d1f899cf6a4dcf3ee"
    static let cipherCtr = "bff16c937d10d82899de28974216e6cf526824592ff2f34ef8e51ae9d870a3b9d0241796ab9d9c598cc1d3abf855a68c"
    static let cipherGcm = "fd0819dba9a8acc3449c691bdd65a8b7983fb5cb4e693675218fedccc964e383ad5139c2ae4779328c6735bad2d0fa06e5e19896913a3565121fc3653f2e7f26"
    static let cipherPbkdf2 = "ee5eba97119961d8756b1f51deac548ad56f854ed9152a6974516aa3b3673a30"
    static let cipherHmac512 = "4141073c0e2f3d2011239df45ebf12517b243d9129730718d3c6458523f780f3f1be16d2e72326af66b7875251074b35f65182bead443e49590b61eb8db9aa49"
    static let sessionAliceIdentity = "28bd0d0bc93b460d940f2126f40bdf6c3a788c7a86eefaedc5de6bc9e702465f"
    static let sessionBobIdentity = "50d4eaf37f8b6c7b352e8575b6e6d81dcfc3813926fe8dd28d1aab0dca084572"
    static let sessionBobSigned = "309cbce15a44b01cd06455f26d9863f441fbfcf5ec8ad4c0a8892813da43c56d"
    static let sessionBobSignature = "7646873cd2d98f9fe3491a1805773e6e45930eb558158384efcbc4abbc7a861b71d553b481447c9666c3d8f603d2a8eba52ce73a5fed78992ec783689c02b48d"
    static let sessionBobOneTime = "007708d9128f5054aaafa6b949c33dacd24d50913efe33546fdd90e5b4535579"
    static let sessionFirst = "330807122105ac4641f920bde31e89374e785b4deaa55518556df1777472ad8eb4b641ce6c1e1a210562be5688c316a57636805cfc906cb1306d928c50aa36f33ef3bc6e5ded1375722242330a210527dd912e451c3b5162659b9e5c7f2d8e2cba62b6dd90ab5b5aec92fe05cfe7261000180022105f62ac8e2e74ba2103a496ad364f9aa7a0738fa0e72a081628d2093001"
    static let sessionSecond = "330807122105ac4641f920bde31e89374e785b4deaa55518556df1777472ad8eb4b641ce6c1e1a210562be5688c316a57636805cfc906cb1306d928c50aa36f33ef3bc6e5ded1375722242330a210527dd912e451c3b5162659b9e5c7f2d8e2cba62b6dd90ab5b5aec92fe05cfe7261001180022108f0eebe293aac6cab765d0f903e1dc845f4a83dce8e75a6a28d2093001"
    static let groupDistribution = "330887ad4b10001a2094869741de62e69e8c2f0a43a46492fa77698c9ecc071ea4128e84c45ac06d3422210588cd1b0c97a991ce631101ba63ce50a14cc43119c1ebdaa91158690f63114243"
    static let groupMessages = [
        "330887ad4b10001a10d185cc58e607abcd9ba10944ac9e518e1604f8a3300713e63bbc2f3d2ef4f44bd99dede192f7f3f0c35ae46bd7f6852260d4f72de41ff83f2acd107d03e37aeabfd7d8f566890c6679e82a7f76f2d289",
        "330887ad4b10011a101591a4f43df41e855f0d2a5f99d92fcc5852656182034f77ef7e440f694c2a4d19ed31e7f68e324e2999bd7f650acb384af0b1a0bab5c63e976476c7c587e3e673c707dc5710399971e6e9e499e8ae83",
        "330887ad4b10021a102e1e776266ef44d05eb150138411ac522d71658fb62043f9b42b3dfec6bd7dadbbbc3cb141b51122759eeffd29238f9d4ebf659e7c43241955d86c6fd9d78b3fcb21e29bd77509d670c97cd03be4788f",
        "330887ad4b10031a1011ca54d3aff1ff86e99db7f4fc1ea0f1dbfd23c9891aee3f986ff3b971ba61009ab56e7bdda44049b8e94bf3108b5f5196053b35797ee1cb4e99f6bc1f518fccc1fc2c8d388b39994dc9ec2c3b94ae89",
    ]
}
