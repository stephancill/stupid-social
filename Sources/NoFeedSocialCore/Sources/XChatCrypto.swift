import CryptoKit
import Foundation
import Security

/// XChat's cryptography, as X's web client (`@x-clients/dm-core`) does it and as validated live in
/// `scripts/xchat-client.py`:
/// - Each account has a P-256 identity key (ECDH) and signing key (ECDSA), recovered from Juicebox with the PIN.
/// - Each conversation key (32 bytes, versioned) is wrapped to every participant's identity key with ECIES.
/// - Message contents (encryption version 0) are a libsodium secretbox (XSalsa20-Poly1305) under the
///   conversation key, stored as nonce || MAC || ciphertext.
/// - Every event is signed over a comma-joined payload, and messages carry a franking tag for abuse reports.
enum XChatCrypto {
    enum CryptoError: LocalizedError {
        case invalidKey
        case invalidCiphertext
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .invalidKey: "An XChat key is malformed."
            case .invalidCiphertext: "An XChat message is malformed."
            case .authenticationFailed: "An XChat message failed to decrypt."
            }
        }
    }

    /// Opens a conversation key wrapped to the identity key: the 65-byte ephemeral public key, then AES-128-GCM
    /// ciphertext and tag, with key and IV from SHA-256(shared secret || 00000001 || ephemeral public key).
    static func unwrapConversationKey(_ wrapped: Data, identityPrivateKey: Data) throws -> Data {
        guard wrapped.count > 65 + 16 else { throw CryptoError.invalidCiphertext }
        let ephemeral = wrapped.prefix(65)
        let sealed = wrapped.dropFirst(65)
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: identityPrivateKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeral))
        var input = shared.withUnsafeBytes { Data($0) }
        input.append(contentsOf: [0, 0, 0, 1])
        input.append(ephemeral)
        let derived = Data(SHA256.hash(data: input))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: derived[16 ..< 32]),
            ciphertext: sealed.dropLast(16),
            tag: sealed.suffix(16),
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: derived[0 ..< 16]))
    }

    /// Message contents and franking nonces: nonce (24) || secretbox(plaintext).
    static func seal(_ plaintext: Data, key: Data, nonce: Data? = nil) throws -> Data {
        let nonce = try nonce ?? randomBytes(24)
        return try nonce + SecretBox.seal(plaintext, nonce: nonce, key: key)
    }

    static func open(_ sealed: Data, key: Data) throws -> Data {
        guard sealed.count >= 24 + 16 else { throw CryptoError.invalidCiphertext }
        return try SecretBox.open(sealed.dropFirst(24), nonce: sealed.prefix(24), key: key)
    }

    /// dm-core's `MessageFranking`: SHA-256 over the context, the plaintext's hash, media hashes, the nonce, the
    /// message id and the conversation id.
    static func frankingTag(plaintext: Data, nonce: Data, messageId: String, conversationId: String, mediaHashes: [Data] = []) -> Data {
        var data = Data("xchat-franking".utf8)
        data.append(Data(SHA256.hash(data: plaintext)))
        data.append(bigEndian: UInt32(mediaHashes.count))
        for hash in mediaHashes {
            data.append(hash)
        }
        data.append(nonce)
        data.append(Data(messageId.utf8))
        data.append(bigEndian: UInt32(conversationId.utf8.count))
        data.append(Data(conversationId.utf8))
        return Data(SHA256.hash(data: data))
    }

    /// ECDSA P-256 / SHA-256 over the payload, as raw r || s.
    static func sign(_ payload: String, signingPrivateKey: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey).signature(for: Data(payload.utf8)).rawRepresentation
    }

    static func isValidSignature(_ signature: Data, payload: String, signingPublicKeyDER: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: signingPublicKeyDER),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(signature, for: Data(payload.utf8))
    }

    /// The public key for a private one, as X registers it (SubjectPublicKeyInfo DER).
    static func signingPublicKeyDER(signingPrivateKey: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey).publicKey.derRepresentation
    }

    static func identityPublicKeyDER(identityPrivateKey: Data) throws -> Data {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: identityPrivateKey).publicKey.derRepresentation
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw CryptoError.invalidKey }
        return Data(bytes)
    }
}

// MARK: Base64

extension Data {
    /// Standard alphabet without padding, as XChat signs ciphertexts and encodes signatures.
    var unpaddedBase64: String {
        base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Standard or URL-safe base64, padded or not.
    init?(lenientBase64 string: String) {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    fileprivate mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

// MARK: XSalsa20-Poly1305

/// libsodium's `crypto_secretbox_easy`: XSalsa20 encryption with a Poly1305 tag, output MAC (16) || ciphertext.
enum SecretBox {
    static func seal(_ plaintext: Data, nonce: Data, key: Data) throws -> Data {
        let (stream, macKey) = try keystream(count: plaintext.count, nonce: nonce, key: key)
        let ciphertext = Data(zip(plaintext, stream).map { $0 ^ $1 })
        return Poly1305.tag(ciphertext, key: macKey) + ciphertext
    }

    static func open(_ box: Data, nonce: Data, key: Data) throws -> Data {
        guard box.count >= 16 else { throw XChatCrypto.CryptoError.invalidCiphertext }
        let tag = box.prefix(16), ciphertext = box.dropFirst(16)
        let (stream, macKey) = try keystream(count: ciphertext.count, nonce: nonce, key: key)
        guard constantTimeEqual(Poly1305.tag(Data(ciphertext), key: macKey), Data(tag)) else {
            throw XChatCrypto.CryptoError.authenticationFailed
        }
        return Data(zip(ciphertext, stream).map { $0 ^ $1 })
    }

    /// The first 32 bytes of the XSalsa20 stream are Poly1305's one-time key; the message uses the rest.
    private static func keystream(count: Int, nonce: Data, key: Data) throws -> (stream: [UInt8], macKey: Data) {
        guard key.count == 32, nonce.count == 24 else { throw XChatCrypto.CryptoError.invalidKey }
        let subkey = Salsa20.hsalsa20(key: [UInt8](key), input: [UInt8](nonce.prefix(16)))
        let stream = Salsa20.stream(key: subkey, nonce: [UInt8](nonce.suffix(8)), count: 32 + count)
        return (Array(stream[32...]), Data(stream[0 ..< 32]))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum Salsa20 {
    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]

    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        let k = words(key), n = words(input)
        var x = [sigma[0], k[0], k[1], k[2], k[3], sigma[1], n[0], n[1], n[2], n[3], sigma[2], k[4], k[5], k[6], k[7], sigma[3]]
        doubleRounds(&x)
        return bytes([x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]])
    }

    static func stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        let k = words(key), n = words(nonce)
        var out = [UInt8]()
        out.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while out.count < count {
            let input = [
                sigma[0], k[0], k[1], k[2], k[3], sigma[1], n[0], n[1],
                UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), sigma[2], k[4], k[5], k[6], k[7], sigma[3],
            ]
            var x = input
            doubleRounds(&x)
            out += bytes(zip(x, input).map { $0 &+ $1 })
            counter += 1
        }
        return Array(out.prefix(count))
    }

    private static func doubleRounds(_ x: inout [UInt32]) {
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[b] ^= (x[a] &+ x[d]).rotatedLeft(7)
            x[c] ^= (x[b] &+ x[a]).rotatedLeft(9)
            x[d] ^= (x[c] &+ x[b]).rotatedLeft(13)
            x[a] ^= (x[d] &+ x[c]).rotatedLeft(18)
        }
        for _ in 0 ..< 10 {
            quarter(0, 4, 8, 12)
            quarter(5, 9, 13, 1)
            quarter(10, 14, 2, 6)
            quarter(15, 3, 7, 11)
            quarter(0, 1, 2, 3)
            quarter(5, 6, 7, 4)
            quarter(10, 11, 8, 9)
            quarter(15, 12, 13, 14)
        }
    }

    private static func words(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { i in
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in (0 ..< 4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } }
    }
}

/// Poly1305 in 26-bit limbs (as in poly1305-donna).
enum Poly1305 {
    static func tag(_ message: Data, key: Data) -> Data {
        let key = [UInt8](key), message = [UInt8](message)
        func le32(_ bytes: [UInt8], _ i: Int) -> UInt64 {
            UInt64(bytes[i]) | UInt64(bytes[i + 1]) << 8 | UInt64(bytes[i + 2]) << 16 | UInt64(bytes[i + 3]) << 24
        }
        let mask: UInt64 = 0x3FFFFFF
        let r0 = le32(key, 0) & 0x3FFFFFF
        let r1 = (le32(key, 3) >> 2) & 0x3FFFF03
        let r2 = (le32(key, 6) >> 4) & 0x3FFC0FF
        let r3 = (le32(key, 9) >> 6) & 0x3F03FFF
        let r4 = (le32(key, 12) >> 8) & 0x00FFFFF
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5
        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0

        var offset = 0
        while offset < message.count {
            var block = [UInt8](repeating: 0, count: 17)
            let length = min(16, message.count - offset)
            block.replaceSubrange(0 ..< length, with: message[offset ..< offset + length])
            block[length] = 1
            let high: UInt64 = length == 16 ? 1 << 24 : 0
            h0 += le32(block, 0) & mask
            h1 += (le32(block, 3) >> 2) & mask
            h2 += (le32(block, 6) >> 4) & mask
            h3 += (le32(block, 9) >> 6) & mask
            // A full block's 0x01 terminator is the high bit; a short block's is already among its bytes.
            h4 += (le32(block, 12) >> 8) | high

            let d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
            h0 = d0 & mask
            d1 += d0 >> 26
            h1 = d1 & mask
            d2 += d1 >> 26
            h2 = d2 & mask
            d3 += d2 >> 26
            h3 = d3 & mask
            d4 += d3 >> 26
            h4 = d4 & mask
            h0 += (d4 >> 26) * 5
            h1 += h0 >> 26
            h0 &= mask
            offset += 16
        }

        var carry = h1 >> 26
        h1 &= mask
        h2 += carry
        carry = h2 >> 26
        h2 &= mask
        h3 += carry
        carry = h3 >> 26
        h3 &= mask
        h4 += carry
        carry = h4 >> 26
        h4 &= mask
        h0 += carry * 5
        carry = h0 >> 26
        h0 &= mask
        h1 += carry

        // h - p, kept when h >= p = 2^130 - 5.
        var g0 = h0 + 5
        carry = g0 >> 26
        g0 &= mask
        var g1 = h1 + carry
        carry = g1 >> 26
        g1 &= mask
        var g2 = h2 + carry
        carry = g2 >> 26
        g2 &= mask
        var g3 = h3 + carry
        carry = g3 >> 26
        g3 &= mask
        let g4 = h4 + carry
        if g4 >= 1 << 26 {
            h0 = g0
            h1 = g1
            h2 = g2
            h3 = g3
            h4 = g4 - (1 << 26)
        }

        let w0 = (h0 | h1 << 26) & 0xFFFF_FFFF
        let w1 = (h1 >> 6 | h2 << 20) & 0xFFFF_FFFF
        let w2 = (h2 >> 12 | h3 << 14) & 0xFFFF_FFFF
        let w3 = (h3 >> 18 | h4 << 8) & 0xFFFF_FFFF
        var out = [UInt8]()
        var f: UInt64 = 0
        for (index, word) in [w0, w1, w2, w3].enumerated() {
            f = word + le32(key, 16 + 4 * index) + (f >> 32)
            for shift in 0 ..< 4 {
                out.append(UInt8(truncatingIfNeeded: f >> (8 * UInt64(shift))))
            }
        }
        return Data(out)
    }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 {
        self << count | self >> (32 - count)
    }
}
