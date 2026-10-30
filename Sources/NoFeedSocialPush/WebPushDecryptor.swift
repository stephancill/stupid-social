import CryptoKit
import Foundation

/// The client half of a Web Push subscription (RFC 8291): a P-256 key pair and a 16-byte auth secret. Apron
/// servers encrypt push payloads to it, so the relay and APNs see only ciphertext (§4.9.2).
public struct WebPushKeys: Codable, Hashable, Sendable {
    /// The raw 32-byte private scalar.
    public let privateKey: Data
    public let auth: Data

    public init(privateKey: Data, auth: Data) {
        self.privateKey = privateKey
        self.auth = auth
    }

    public static func generate() -> WebPushKeys {
        var auth = SystemRandomNumberGenerator()
        return WebPushKeys(
            privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation,
            auth: Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &auth) }),
        )
    }

    /// The uncompressed public point, `p256dh` in a registration.
    public var publicKey: Data {
        get throws { try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation }
    }
}

public enum WebPushError: Error, Equatable {
    case malformed
    case decryptionFailed
}

public enum WebPushDecryptor {
    /// Decrypts one `aes128gcm` record (RFC 8188) with the Web Push key schedule (RFC 8291 §3.4).
    public static func decrypt(_ body: Data, keys: WebPushKeys) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count > 21 else { throw WebPushError.malformed }
        let salt = Data(bytes[0 ..< 16])
        let recordSize = bytes[16 ..< 20].reduce(0) { $0 << 8 | Int($1) }
        let keyIdLength = Int(bytes[20])
        guard bytes.count >= 21 + keyIdLength + 16 else { throw WebPushError.malformed }
        let senderPublic = Data(bytes[21 ..< 21 + keyIdLength])
        let record = Data(bytes[(21 + keyIdLength)...])
        guard record.count <= recordSize else { throw WebPushError.malformed }

        do {
            let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey)
            let sender = try P256.KeyAgreement.PublicKey(x963Representation: senderPublic)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: sender)
            let info = Data("WebPush: info\0".utf8) + privateKey.publicKey.x963Representation + senderPublic
            let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: keys.auth, sharedInfo: info, outputByteCount: 32)
            let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
            let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
                ciphertext: record.dropLast(16),
                tag: record.suffix(16),
            )
            let padded = try AES.GCM.open(box, using: cek)
            // The last record ends with the delimiter 0x02, then any zero padding.
            guard let delimiter = padded.lastIndex(where: { $0 != 0 }), padded[delimiter] == 2 else { throw WebPushError.malformed }
            return padded[padded.startIndex ..< delimiter]
        } catch let error as WebPushError {
            throw error
        } catch {
            throw WebPushError.decryptionFailed
        }
    }
}

public extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum WebPushEncryptor {
    /// Encrypts `plaintext` as one `aes128gcm` record (RFC 8188) to a subscription's `p256dh` and auth secret
    /// (RFC 8291), what `WebPushDecryptor.decrypt` reads.
    public static func encrypt(_ plaintext: Data, publicKey: Data, auth: Data) throws -> Data {
        let receiver = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let sender = P256.KeyAgreement.PrivateKey()
        let senderPublic = sender.publicKey.x963Representation
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })

        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        let info = Data("WebPush: info\0".utf8) + publicKey + senderPublic
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: info, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let box = try AES.GCM.seal(plaintext + [2], using: cek, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
        let record = box.ciphertext + box.tag
        let recordSize = UInt32(record.count)
        let header = salt + withUnsafeBytes(of: recordSize.bigEndian) { Data($0) } + [UInt8(senderPublic.count)] + senderPublic
        return header + record
    }
}
