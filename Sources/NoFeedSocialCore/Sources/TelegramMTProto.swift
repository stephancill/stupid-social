import Foundation
import Network

public enum TelegramError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case connectionLost
    case authKeyInvalid
    case protocolViolation(String)
    case rpc(code: Int32, message: String)
    /// A user this device can't name to Telegram, such as one it hasn't seen in a chat yet.
    case unknownUser
    /// An `@username` that belongs to a channel or group rather than a person.
    case notAPerson

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Telegram isn't available in this build."
        case .notSignedIn: "Not signed in to Telegram."
        case .connectionLost: "Lost the connection to Telegram."
        case .authKeyInvalid: "Telegram no longer knows this device's key."
        case let .protocolViolation(reason): "Telegram protocol error: \(reason)."
        case let .rpc(code, message): Self.describe(code: code, message: message)
        case .unknownUser: "This profile isn't available yet. Open a chat they're in, then try again."
        case .notAPerson: "That's a channel or group, not a person."
        }
    }

    private static func describe(code: Int32, message: String) -> String {
        switch message {
        case "PHONE_NUMBER_INVALID": "That phone number isn't valid."
        case "PHONE_CODE_INVALID": "That code isn't right."
        case "PHONE_CODE_EXPIRED": "That code expired. Request a new one."
        case "PASSWORD_HASH_INVALID": "That password isn't right."
        case "PHONE_NUMBER_UNOCCUPIED": "There's no Telegram account for this number."
        case "USERNAME_NOT_OCCUPIED", "USERNAME_INVALID": "There's no one on Telegram with that username."
        default:
            if message.hasPrefix("FLOOD_WAIT_"), let seconds = Int(message.dropFirst("FLOOD_WAIT_".count)) {
                "Telegram asked to wait \(seconds) seconds."
            } else {
                "Telegram error \(code): \(message)"
            }
        }
    }
}

/// An auth key for one DC, with the server salt and clock offset that go with it.
public struct TelegramDCKey: Codable, Sendable, Equatable {
    public var authKey: Data
    public var salt: Int64
    public var timeOffset: Double
}

/// The MTProto intermediate transport over TCP: a 0xeeeeeeee header, then length-prefixed packets.
final class TelegramTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "net.stupidtech.telegram.transport")

    init(host: String, port: UInt16 = 443) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    /// Whether `start` has resumed; only touched on the transport queue.
    private final class Started: @unchecked Sendable {
        var value = false
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let started = Started()
            connection.stateUpdateHandler = { state in
                guard !started.value else { return }
                switch state {
                case .ready:
                    started.value = true
                    continuation.resume()
                case let .failed(error), let .waiting(error):
                    started.value = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    started.value = true
                    continuation.resume(throwing: TelegramError.connectionLost)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        try await write(Data([0xEE, 0xEE, 0xEE, 0xEE]))
    }

    func send(packet: Data) async throws {
        var length = UInt32(packet.count).littleEndian
        try await write(Data(bytes: &length, count: 4) + packet)
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receivePacket() async throws -> Data {
        let header = try await read(4)
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        let packet = try await read(length)
        if length == 4 {
            let code = Int32(bitPattern: UInt32(packet[0]) | UInt32(packet[1]) << 8 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 24)
            throw code == -404 ? TelegramError.authKeyInvalid : TelegramError.protocolViolation("transport error \(code)")
        }
        return packet
    }

    private func read(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: TelegramError.connectionLost)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            data.append(chunk)
        }
        return data
    }

    func close() {
        connection.cancel()
    }
}

/// One encrypted MTProto 2.0 session on a DC: RPC calls matched to results, service messages (salts, clock
/// fixes, acks, containers, gzip) and updates pushed by the server. Validated against
/// `scripts/telegram-client.py`, which follows the same steps.
actor MTProtoSession {
    static let addresses: [Int: String] = [
        1: "149.154.175.53",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "91.108.56.130",
    ]

    private struct Pending {
        let body: Data
        let type: TLType
        let continuation: CheckedContinuation<TLValue, Error>
    }

    let dc: Int
    private let transport: TelegramTransport
    private var key: TelegramDCKey
    private let authKeyId: Data
    private let sessionId = TelegramCrypto.randomBytes(8)
    private var sequence: Int32 = 0
    private var lastMessageId: Int64 = 0
    private var pending: [Int64: Pending] = [:]
    private var pendingAcks: [Int64] = []
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private(set) var isClosed = false
    private let schema = TLSchema.shared
    private let onUpdate: @Sendable (TLObject) -> Void
    private let onKeyChange: @Sendable (Int, TelegramDCKey) -> Void

    /// Connects to `dc`, creating an auth key there when there isn't one, and starts the session.
    static func open(
        dc: Int,
        key existing: TelegramDCKey?,
        onUpdate: @escaping @Sendable (TLObject) -> Void,
        onKeyChange: @escaping @Sendable (Int, TelegramDCKey) -> Void,
    ) async throws -> MTProtoSession {
        guard let address = addresses[dc] else { throw TelegramError.protocolViolation("unknown DC \(dc)") }
        let transport = TelegramTransport(host: address)
        try await transport.start()
        let key: TelegramDCKey
        if let existing {
            key = existing
        } else {
            key = try await createAuthKey(transport: transport, dc: dc)
            onKeyChange(dc, key)
        }
        let session = MTProtoSession(dc: dc, transport: transport, key: key, onUpdate: onUpdate, onKeyChange: onKeyChange)
        await session.start()
        return session
    }

    private init(dc: Int, transport: TelegramTransport, key: TelegramDCKey, onUpdate: @escaping @Sendable (TLObject) -> Void, onKeyChange: @escaping @Sendable (Int, TelegramDCKey) -> Void) {
        self.dc = dc
        self.transport = transport
        self.key = key
        authKeyId = TelegramCrypto.sha1(key.authKey).suffix(8)
        self.onUpdate = onUpdate
        self.onKeyChange = onKeyChange
    }

    private func start() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                await ping()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        pingTask?.cancel()
        transport.close()
        failAll(TelegramError.connectionLost)
    }

    // MARK: Calls

    func call(_ method: TLObject) async throws -> TLValue {
        guard !isClosed else { throw TelegramError.connectionLost }
        let type = try schema.resultType(of: method)
        var writer = TLWriter(schema: schema)
        try writer.object(method)
        let body = writer.data
        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.send(body: body, type: type, continuation: continuation) }
        }
    }

    private func send(body: Data, type: TLType, continuation: CheckedContinuation<TLValue, Error>) async {
        guard !isClosed else {
            continuation.resume(throwing: TelegramError.connectionLost)
            return
        }
        let messageId = nextMessageId()
        pending[messageId] = Pending(body: body, type: type, continuation: continuation)
        Task { [weak self] in
            try? await Task.sleep(for: Self.callTimeout)
            await self?.timeOut(messageId)
        }
        do {
            try await transport.send(packet: encrypt(messageId: messageId, seqNo: nextSeqNo(contentRelated: true), body: body))
        } catch {
            // A socket iOS dropped while suspended fails writes (POSIX 57, "Socket is not connected"). Closing fails
            // this call and the others as `connectionLost`, which the client answers by reconnecting and retrying.
            close()
        }
    }

    /// A socket iOS dropped while suspended can stay silent, so a call without an answer closes the session,
    /// failing its calls as `connectionLost` for the client to reconnect.
    private static let callTimeout: Duration = .seconds(25)

    private func timeOut(_ messageId: Int64) {
        guard pending[messageId] != nil else { return }
        close()
    }

    private func resend(_ badMessageId: Int64) async {
        guard let entry = pending.removeValue(forKey: badMessageId) else { return }
        await send(body: entry.body, type: entry.type, continuation: entry.continuation)
    }

    private func ping() async {
        var writer = TLWriter(schema: schema)
        try? writer.object(TLObject("ping_delay_disconnect", ["ping_id": .long(Int64.random(in: 1 ... .max)), "disconnect_delay": .int(75)]))
        do {
            try await transport.send(packet: encrypt(messageId: nextMessageId(), seqNo: nextSeqNo(contentRelated: true), body: writer.data))
        } catch {
            close()
        }
    }

    private func flushAcks() async {
        guard !pendingAcks.isEmpty else { return }
        let acks = pendingAcks
        pendingAcks = []
        var writer = TLWriter(schema: schema)
        try? writer.object(TLObject("msgs_ack", ["msg_ids": .vector(acks.map { .long($0) })]))
        try? await transport.send(packet: encrypt(messageId: nextMessageId(), seqNo: nextSeqNo(contentRelated: false), body: writer.data))
    }

    private func nextMessageId() -> Int64 {
        let now = Date().timeIntervalSince1970 + key.timeOffset
        let seconds = Int64(now)
        let fraction = Int64(UInt32((now - Double(seconds)) * 4_294_967_296.0) & ~3)
        var id = seconds << 32 | fraction
        if id <= lastMessageId {
            id = lastMessageId + 4
        }
        lastMessageId = id
        return id
    }

    private func nextSeqNo(contentRelated: Bool) -> Int32 {
        guard contentRelated else { return sequence * 2 }
        defer { sequence += 1 }
        return sequence * 2 + 1
    }

    private func failAll(_ error: Error) {
        let calls = pending.values
        pending = [:]
        for call in calls {
            call.continuation.resume(throwing: error)
        }
    }

    // MARK: Encryption

    private func keys(msgKey: Data, x: Int) -> (key: Data, iv: Data) {
        let authKey = key.authKey
        let a = TelegramCrypto.sha256(msgKey + authKey[x ..< x + 36])
        let b = TelegramCrypto.sha256(authKey[40 + x ..< 76 + x] + msgKey)
        return (a[0 ..< 8] + b[8 ..< 24] + a[24 ..< 32], b[0 ..< 8] + a[8 ..< 24] + b[24 ..< 32])
    }

    private func encrypt(messageId: Int64, seqNo: Int32, body: Data) -> Data {
        var writer = TLWriter(schema: schema)
        writer.int64(key.salt)
        writer.raw(sessionId)
        writer.int64(messageId)
        writer.int32(seqNo)
        writer.int32(Int32(body.count))
        writer.raw(body)
        var plain = writer.data
        let padding = 12 + (16 - (plain.count + 12) % 16) % 16
        plain.append(TelegramCrypto.randomBytes(padding))
        let msgKey = TelegramCrypto.sha256(key.authKey[88 ..< 120] + plain)[8 ..< 24]
        let (aesKey, iv) = keys(msgKey: Data(msgKey), x: 0)
        return authKeyId + msgKey + TelegramCrypto.ige(plain, key: aesKey, iv: iv, encrypt: true)
    }

    private func decrypt(_ packet: Data) throws -> (messageId: Int64, seqNo: Int32, body: Data) {
        guard packet.count >= 24 + 32, packet.prefix(8) == authKeyId else { throw TelegramError.protocolViolation("auth_key_id mismatch") }
        let msgKey = Data(packet[packet.startIndex + 8 ..< packet.startIndex + 24])
        let (aesKey, iv) = keys(msgKey: msgKey, x: 8)
        let plain = TelegramCrypto.ige(Data(packet.dropFirst(24)), key: aesKey, iv: iv, encrypt: false)
        guard TelegramCrypto.sha256(key.authKey[96 ..< 128] + plain)[8 ..< 24] == msgKey else { throw TelegramError.protocolViolation("msg_key mismatch") }
        guard plain[8 ..< 16] == sessionId else { throw TelegramError.protocolViolation("session_id mismatch") }
        var reader = TLReader(plain, schema: schema)
        reader.offset = 16
        let messageId = try reader.int64()
        let seqNo = try reader.int32()
        let length = try Int(reader.int32())
        guard length >= 0, length <= reader.remaining else { throw TelegramError.protocolViolation("bad message length") }
        return try (messageId, seqNo, reader.take(length))
    }

    // MARK: Receiving

    private func receiveLoop() async {
        while !Task.isCancelled, !isClosed {
            do {
                let packet = try await transport.receivePacket()
                let message = try decrypt(packet)
                await handle(messageId: message.messageId, seqNo: message.seqNo, body: message.body)
                await flushAcks()
            } catch {
                guard !isClosed else { return }
                isClosed = true
                pingTask?.cancel()
                transport.close()
                failAll(error is TelegramError ? error : TelegramError.connectionLost)
                return
            }
        }
    }

    private func handle(messageId: Int64, seqNo: Int32, body: Data) async {
        if seqNo & 1 == 1 {
            pendingAcks.append(messageId)
        }
        var reader = TLReader(body, schema: schema)
        guard let id = reader.peekUInt32() else { return }
        switch id {
        case 0x73F1_F8DC: // msg_container
            _ = try? reader.uint32()
            guard let count = try? reader.int32() else { return }
            for _ in 0 ..< count {
                guard let innerId = try? reader.int64(), let innerSeqNo = try? reader.int32(), let length = try? reader.int32(),
                      let innerBody = try? reader.take(Int(length))
                else { return }
                await handle(messageId: innerId, seqNo: innerSeqNo, body: innerBody)
            }
        case 0x3072_CFA1: // gzip_packed
            _ = try? reader.uint32()
            guard let packed = try? reader.tlBytes(), let inflated = try? TLReader.gunzip(packed) else { return }
            await handle(messageId: messageId, seqNo: seqNo & ~1, body: inflated)
        case 0xF35C_6D01: // rpc_result
            _ = try? reader.uint32()
            guard let requestId = try? reader.int64(), let call = pending.removeValue(forKey: requestId) else { return }
            if reader.peekUInt32() == 0x2144_CA19 {
                let error = (try? reader.value(.boxed("RpcError")))?.object
                call.continuation.resume(throwing: TelegramError.rpc(code: error?["error_code"]?.int ?? 0, message: error?["error_message"]?.string ?? "UNKNOWN"))
                return
            }
            do {
                try call.continuation.resume(returning: reader.value(call.type))
            } catch {
                call.continuation.resume(throwing: error)
            }
        default:
            guard let object = (try? reader.value(.boxed("Object")))?.object else { return }
            await handleService(object, messageId: messageId)
        }
    }

    private func handleService(_ object: TLObject, messageId: Int64) async {
        switch object.name {
        case "bad_server_salt":
            key.salt = object["new_server_salt"]?.long ?? key.salt
            onKeyChange(dc, key)
            if let bad = object["bad_msg_id"]?.long {
                await resend(bad)
            }
        case "bad_msg_notification":
            let code = object["error_code"]?.int ?? 0
            guard let bad = object["bad_msg_id"]?.long else { return }
            if code == 16 || code == 17 {
                key.timeOffset = Double(messageId >> 32) - Date().timeIntervalSince1970
                onKeyChange(dc, key)
                await resend(bad)
            } else if let call = pending.removeValue(forKey: bad) {
                call.continuation.resume(throwing: TelegramError.protocolViolation("bad_msg_notification \(code)"))
            }
        case "new_session_created":
            if let salt = object["server_salt"]?.long {
                key.salt = salt
                onKeyChange(dc, key)
            }
        default:
            if object.name.hasPrefix("update") {
                onUpdate(object)
            }
        }
    }

    // MARK: Auth key exchange

    private static func plainCall(_ method: TLObject, transport: TelegramTransport, messageId: Int64) async throws -> TLObject {
        let schema = TLSchema.shared
        var body = TLWriter(schema: schema)
        try body.object(method)
        var writer = TLWriter(schema: schema)
        writer.int64(0)
        writer.int64(messageId)
        writer.int32(Int32(body.data.count))
        writer.raw(body.data)
        try await transport.send(packet: writer.data)
        var reader = try await TLReader(transport.receivePacket(), schema: schema)
        guard try reader.int64() == 0 else { throw TelegramError.protocolViolation("encrypted reply during key exchange") }
        _ = try reader.int64()
        let length = try Int(reader.int32())
        var inner = try TLReader(reader.take(length), schema: schema)
        guard let object = try inner.value(schema.resultType(of: method)).object else { throw TelegramError.protocolViolation("bad key exchange reply") }
        return object
    }

    /// Creates an auth key with the DC (https://core.telegram.org/mtproto/auth_key).
    static func createAuthKey(transport: TelegramTransport, dc: Int) async throws -> TelegramDCKey {
        var messageId = Int64(Date().timeIntervalSince1970) << 32
        func nextId() -> Int64 {
            messageId += 4
            return messageId
        }
        let nonce = TelegramCrypto.randomBytes(16)
        let resPQ = try await plainCall(TLObject("req_pq_multi", ["nonce": .bytes(nonce)]), transport: transport, messageId: nextId())
        guard resPQ["nonce"]?.bytes == nonce, let serverNonce = resPQ["server_nonce"]?.bytes, let pqBytes = resPQ["pq"]?.bytes else {
            throw TelegramError.protocolViolation("bad resPQ")
        }
        guard (resPQ["server_public_key_fingerprints"]?.vector ?? []).contains(.long(TelegramCrypto.rsaFingerprint)) else {
            throw TelegramError.protocolViolation("server doesn't offer the known RSA key")
        }
        let pq = pqBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let (p, q) = TelegramCrypto.factorize(pq)
        let pBytes = BigUInt(p).bytes()
        let qBytes = BigUInt(q).bytes()
        let newNonce = TelegramCrypto.randomBytes(32)
        var inner = TLWriter()
        try inner.object(TLObject("p_q_inner_data_dc", [
            "pq": .bytes(pqBytes), "p": .bytes(pBytes), "q": .bytes(qBytes),
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "new_nonce": .bytes(newNonce), "dc": .int(Int32(dc)),
        ]))
        let dhParams = try await plainCall(TLObject("req_DH_params", [
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "p": .bytes(pBytes), "q": .bytes(qBytes),
            "public_key_fingerprint": .long(TelegramCrypto.rsaFingerprint), "encrypted_data": .bytes(TelegramCrypto.rsaPad(inner.data)),
        ]), transport: transport, messageId: nextId())
        guard dhParams.name == "server_DH_params_ok", let encryptedAnswer = dhParams["encrypted_answer"]?.bytes else {
            throw TelegramError.protocolViolation("DH params refused")
        }
        let sha1 = TelegramCrypto.sha1
        let tmpKey = sha1(newNonce + serverNonce) + sha1(serverNonce + newNonce).prefix(12)
        let tmpIV = sha1(serverNonce + newNonce).suffix(8) + sha1(newNonce + newNonce) + newNonce.prefix(4)
        let answerWithHash = TelegramCrypto.ige(encryptedAnswer, key: tmpKey, iv: tmpIV, encrypt: false)
        var answerReader = TLReader(answerWithHash.dropFirst(20))
        guard let answer = try answerReader.value(.boxed("Server_DH_inner_data")).object else { throw TelegramError.protocolViolation("bad DH answer") }
        let answerLength = answerReader.offset - answerWithHash.dropFirst(20).startIndex
        guard sha1(answerWithHash.dropFirst(20).prefix(answerLength)) == answerWithHash.prefix(20),
              answer["nonce"]?.bytes == nonce, answer["server_nonce"]?.bytes == serverNonce
        else { throw TelegramError.protocolViolation("DH answer hash mismatch") }
        guard let primeBytes = answer["dh_prime"]?.bytes, BigUInt(bytes: primeBytes) == TelegramCrypto.dhPrime,
              let g = answer["g"]?.int, let gABytes = answer["g_a"]?.bytes, let serverTime = answer["server_time"]?.int
        else { throw TelegramError.protocolViolation("unexpected DH prime") }
        let prime = TelegramCrypto.dhPrime
        let gA = BigUInt(bytes: gABytes)
        var bound = BigUInt(1)
        for _ in 0 ..< 1984 {
            bound = bound + bound
        }
        guard bound < gA, gA + bound < prime else { throw TelegramError.protocolViolation("g_a out of range") }
        let timeOffset = Double(serverTime) - Date().timeIntervalSince1970
        let mont = Montgomery(modulus: prime)
        let b = BigUInt(bytes: TelegramCrypto.randomBytes(256))
        let gB = mont.power(BigUInt(UInt64(g)), b)
        var clientInner = TLWriter()
        try clientInner.object(TLObject("client_DH_inner_data", [
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "retry_id": .long(0), "g_b": .bytes(gB.bytes()),
        ]))
        var data = sha1(clientInner.data) + clientInner.data
        data.append(TelegramCrypto.randomBytes((16 - data.count % 16) % 16))
        let result = try await plainCall(TLObject("set_client_DH_params", [
            "nonce": .bytes(nonce), "server_nonce": .bytes(serverNonce), "encrypted_data": .bytes(TelegramCrypto.ige(data, key: tmpKey, iv: tmpIV, encrypt: true)),
        ]), transport: transport, messageId: nextId())
        let authKey = mont.power(gA, b).bytes(length: 256)
        guard result.name == "dh_gen_ok",
              result["new_nonce_hash1"]?.bytes == sha1(newNonce + Data([1]) + sha1(authKey).prefix(8)).suffix(16)
        else { throw TelegramError.protocolViolation("DH generation failed") }
        let saltBytes = TelegramCrypto.xor(newNonce.prefix(8), serverNonce.prefix(8))
        let salt = saltBytes.reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
        return TelegramDCKey(authKey: authKey, salt: salt, timeOffset: timeOffset)
    }
}
