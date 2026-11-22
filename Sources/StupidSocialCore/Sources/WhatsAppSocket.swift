import CryptoKit
import Foundation

/// The WebSocket to WhatsApp's chat server with its Noise transport (`XX_25519_AESGCM_SHA256`), as
/// `scripts/whatsapp-client.py` and whatsmeow (`socket/`, `handshake.go`) speak it. Frames are a 3-byte length
/// then the payload; the first frame carries the `WA` header. After the handshake every frame is AES-GCM with
/// counter nonces, holding one binary XML node.
///
/// Owned by `WhatsAppClient`: one task reads while sends come from the client's actor, in order.
final class WhatsAppSocket: @unchecked Sendable {
    private static let url = URL(string: "wss://web.whatsapp.com/ws/chat")!
    static let origin = "https://web.whatsapp.com"
    private static let noisePattern = Data("Noise_XX_25519_AESGCM_SHA256\0\0\0\0".utf8)
    /// WhatsApp's root noise certificate key, the intermediate certificate's issuer (whatsmeow `handshake.go`).
    private static let rootKey = Data(hex: "142375574d0a587166aae71ebe516437c4a28b73e3695c6ce1f7f9545da8ee6b")

    private let task: URLSessionWebSocketTask
    private var header: Data? = Data([0x57, 0x41, 6, UInt8(WhatsAppTokens.shared.dictVersion)])
    private var buffer = Data()
    private var writeKey: SymmetricKey?
    private var readKey: SymmetricKey?
    private var writeCounter: UInt32 = 0
    private var readCounter: UInt32 = 0
    private let lock = NSLock()

    init() {
        var request = URLRequest(url: Self.url)
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 24
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Frames

    private func sendFrame(_ payload: Data) async throws {
        let frame: Data = lock.withLock {
            var frame = header ?? Data()
            header = nil
            frame.append(UInt8(payload.count >> 16 & 0xFF))
            frame.append(UInt8(payload.count >> 8 & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
            frame.append(payload)
            return frame
        }
        try await task.send(.data(frame))
    }

    private func receiveFrame() async throws -> Data {
        while true {
            if buffer.count >= 3 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) << 16 | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2])
                if buffer.count >= 3 + length {
                    let frame = Data(buffer[start + 3 ..< start + 3 + length])
                    buffer = Data(buffer[(start + 3 + length)...])
                    return frame
                }
            }
            switch try await task.receive() {
            case let .data(data): buffer.append(data)
            case let .string(text): buffer.append(Data(text.utf8))
            @unknown default: break
            }
        }
    }

    // MARK: Handshake

    /// Runs the Noise handshake, sending `payload` (a `ClientPayload`) encrypted in the client finish.
    func handshake(noiseKey: WhatsAppKeyPair, payload: Data) async throws {
        let ephemeral = WhatsAppKeyPair.generate()
        var noise = NoiseState(header: header ?? Data())
        noise.authenticate(ephemeral.publicKey)
        let hello = WhatsAppProto.HandshakeMessage(clientHello: .init(ephemeral: ephemeral.publicKey))
        try await sendFrame(hello.serialized())

        let response = try await WhatsAppProto.HandshakeMessage(data: receiveFrame())
        guard let server = response.serverHello, server.ephemeral.count == 32 else { throw WhatsAppError.handshakeFailed }
        noise.authenticate(server.ephemeral)
        try noise.mix(ephemeral.agree(with: server.ephemeral))
        let serverStatic = try noise.decrypt(server.staticKey)
        guard serverStatic.count == 32 else { throw WhatsAppError.handshakeFailed }
        try noise.mix(ephemeral.agree(with: serverStatic))
        try Self.verifyCertificate(noise.decrypt(server.payload), serverStatic: serverStatic)

        let encryptedStatic = try noise.encrypt(noiseKey.publicKey)
        try noise.mix(noiseKey.agree(with: server.ephemeral))
        let finish = try WhatsAppProto.HandshakeMessage(clientFinish: .init(staticKey: encryptedStatic, payload: noise.encrypt(payload)))
        try await sendFrame(finish.serialized())
        let keys = noise.finish()
        writeKey = keys.write
        readKey = keys.read
    }

    private static func verifyCertificate(_ data: Data, serverStatic: Data) throws {
        let chain = try WhatsAppProto.CertChain(data: data)
        guard let intermediate = chain.intermediate, let leaf = chain.leaf,
              WhatsAppXEdDSA.verify(publicKey: rootKey, message: intermediate.details, signature: intermediate.signature)
        else { throw WhatsAppError.badCertificate }
        let intermediateDetails = try WhatsAppProto.CertChain.Details(data: intermediate.details)
        guard intermediateDetails.issuerSerial == 0,
              WhatsAppXEdDSA.verify(publicKey: intermediateDetails.key, message: leaf.details, signature: leaf.signature)
        else { throw WhatsAppError.badCertificate }
        let leafDetails = try WhatsAppProto.CertChain.Details(data: leaf.details)
        let now = UInt64(Date().timeIntervalSince1970)
        guard leafDetails.issuerSerial == intermediateDetails.serial, leafDetails.key == serverStatic,
              [intermediateDetails, leafDetails].allSatisfy({ $0.notBefore <= now && now <= $0.notAfter })
        else { throw WhatsAppError.badCertificate }
    }

    // MARK: Nodes

    func send(_ node: WhatsAppNode) async throws {
        guard let writeKey else { throw WhatsAppError.notConnected }
        let ciphertext: Data = try lock.withLock {
            defer { writeCounter += 1 }
            return try WhatsAppCipher.aesGCMSeal(key: writeKey.withUnsafeBytes { Data($0) }, nonce: Self.nonce(writeCounter), node.encoded())
        }
        try await sendFrame(ciphertext)
    }

    func receive() async throws -> WhatsAppNode {
        guard let readKey else { throw WhatsAppError.notConnected }
        let frame = try await receiveFrame()
        let plaintext = try WhatsAppCipher.aesGCMOpen(key: readKey.withUnsafeBytes { Data($0) }, nonce: Self.nonce(readCounter), frame)
        readCounter += 1
        return try WhatsAppNode.decode(frame: plaintext)
    }

    static func nonce(_ counter: UInt32) -> Data {
        Data(repeating: 0, count: 8) + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    /// The handshake's symmetric state (whatsmeow `socket/noisehandshake.go`).
    private struct NoiseState {
        var hash: Data
        var salt: Data
        var key: Data
        var counter: UInt32 = 0

        init(header: Data) {
            hash = WhatsAppSocket.noisePattern.count == 32 ? WhatsAppSocket.noisePattern : WhatsAppCipher.sha256(WhatsAppSocket.noisePattern)
            salt = hash
            key = hash
            authenticate(header)
        }

        mutating func authenticate(_ data: Data) {
            hash = WhatsAppCipher.sha256(hash + data)
        }

        mutating func encrypt(_ plaintext: Data) throws -> Data {
            let ciphertext = try WhatsAppCipher.aesGCMSeal(key: key, nonce: WhatsAppSocket.nonce(counter), plaintext, authenticating: hash)
            counter += 1
            authenticate(ciphertext)
            return ciphertext
        }

        mutating func decrypt(_ ciphertext: Data) throws -> Data {
            let plaintext = try WhatsAppCipher.aesGCMOpen(key: key, nonce: WhatsAppSocket.nonce(counter), ciphertext, authenticating: hash)
            counter += 1
            authenticate(ciphertext)
            return plaintext
        }

        mutating func mix(_ secret: Data) {
            counter = 0
            let keys = WhatsAppCipher.hkdf(secret, length: 64, salt: salt)
            salt = keys.prefix(32)
            key = keys.suffix(32)
        }

        func finish() -> (write: SymmetricKey, read: SymmetricKey) {
            let keys = WhatsAppCipher.hkdf(Data(), length: 64, salt: salt)
            return (SymmetricKey(data: keys.prefix(32)), SymmetricKey(data: keys.suffix(32)))
        }
    }
}
