import Foundation
import OSLog

public struct WhatsAppAccount: Sendable, Equatable {
    public let jid: WhatsAppJID
    public let lid: WhatsAppJID?
    public let pushName: String?

    /// The international number without `+`.
    public var phoneNumber: String {
        jid.user
    }
}

public enum WhatsAppLinkUpdate: Sendable {
    case qr(String)
    case pairingCode(String)
    case paired
}

public enum WhatsAppError: Error, Equatable {
    case handshakeFailed
    case badCertificate
    case notConnected
    case notLinked
    case linkExpired
    case pairingFailed
    case clientOutdated
    case banned
    case loggedOut
    /// Another connection of this device took over.
    case replaced
    case connectFailure(Int)
    case streamError(String)
    case iq(code: String, text: String)
    case timeout
    case noLID
    case sendFailed(String)
    case unsupported
    case download
    /// The media host no longer has the file (403, 404 or 410): the phone has to upload it again.
    case mediaExpired
    /// The phone no longer has the file either.
    case mediaUnavailable
    case upload
}

/// What changed in the store, for the Chats list and open chats.
public struct WhatsAppChanges: Sendable {
    public var chats: Set<String> = []
    public var reloadList = false
    /// Typing changes: the chat, who, and whether they're typing now.
    public var typing: [WhatsAppTyping] = []

    var isEmpty: Bool {
        chats.isEmpty && !reloadList && typing.isEmpty
    }
}

public struct WhatsAppTyping: Sendable {
    public let chat: String
    public let sender: String
    public let isTyping: Bool
}

/// What a chat shows when it opens or refreshes.
public struct WhatsAppChatPage: Sendable {
    public let title: String?
    public let messages: [WhatsAppMessage]
    /// Senders' display names by JID.
    public let names: [String: String]
    public let readUpTo: Date?
    public let isGroup: Bool
    /// The chat's picture, and senders' pictures by JID, as far as they are looked up.
    public let avatarURL: URL?
    public let avatars: [String: URL]
}

/// The linked device's own keys, in the Keychain: never synchronizable, since each device is its own WhatsApp
/// device.
struct WhatsAppDevice: Codable {
    var noiseKey: WhatsAppKeyPair
    var identityKey: WhatsAppKeyPair
    var signedPreKey: WhatsAppSignedPreKey
    var registrationId: UInt32
    var advSecret: Data
    var version: [UInt32]
    var jid: WhatsAppJID?
    var lid: WhatsAppJID?
    /// The signed device identity from pairing, sent with prekey messages.
    var account: Data?
    var pushName: String?

    static func generate(version: [UInt32]) -> WhatsAppDevice {
        let identity = WhatsAppKeyPair.generate()
        let signed = WhatsAppKeyPair.generate()
        return WhatsAppDevice(
            noiseKey: .generate(), identityKey: identity,
            signedPreKey: WhatsAppSignedPreKey(id: 1, keyPair: signed, signature: identity.sign(Data([5]) + signed.publicKey)),
            registrationId: UInt32.random(in: 1 ... UInt32.max), advSecret: WhatsAppCipher.randomBytes(32), version: version,
        )
    }

    var appVersion: WhatsAppProto.AppVersion {
        WhatsAppProto.AppVersion(version[0], version[1], version[2])
    }
}

/// The Signal state, one-time prekeys and app state keys and hashes, in a file next to the chats.
struct WhatsAppKeyState: Codable {
    struct AppStateKey: Codable {
        var data: Data
        var timestamp: Int64
    }

    struct Collection: Codable {
        var version: UInt64
        var hash: Data
        /// Base64 index MAC → value MAC.
        var macs: [String: Data]
    }

    var signal = WhatsAppSignalState()
    var preKeys: [String: WhatsAppKeyPair] = [:]
    var nextPreKeyId: UInt32 = 1
    var uploadedPreKeyId: UInt32 = 0
    var appStateKeys: [String: AppStateKey] = [:]
    var collections: [String: Collection] = [:]
    var readReceipts = true
    /// Privacy tokens by LID user (whatsmeow tctoken.go). Optional so key files from before them still decode.
    var privacyTokens: [String: PrivacyToken]?

    struct PrivacyToken: Codable {
        /// Their token for us, sent with messages, presence subscriptions and picture requests.
        var token: Data?
        var timestamp: Int64
        /// When we last issued our token to them.
        var senderTimestamp: Int64
    }
}

/// A WhatsApp account as a linked device (WhatsApp's multi-device protocol, validated with
/// `scripts/whatsapp-client.py`, which ports whatsmeow). Links, logs in, decrypts what arrives in order and
/// keeps chats and messages in its `WhatsAppStore`, sends text and receipts.
public actor WhatsAppClient {
    static let collections = ["critical_block", "critical_unblock_low", "regular_high", "regular", "regular_low"]
    private static let initialPreKeyCount = 812
    private static let wantedPreKeyCount = 50
    private static let minimumPreKeyCount = 5
    /// Pictures looked up at login, for the newest chats; others when their chat opens. Bulk picture lookups are
    /// suspected in restrictions of unofficial clients (whatsmeow and Baileys issues), so this stays small.
    private static let avatarPrefetchCount = 20
    /// Lookups are spaced out, as a person scrolling WhatsApp Web would make them.
    private static let avatarSpacing: Duration = .seconds(1)
    private static let linkingAlphabet = Array("123456789ABCDEFGHJKLMNPQRSTVWXYZ")

    private let keychain: KeychainCredentialStore
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "WhatsAppClient")
    private var device: WhatsAppDevice?
    private var keys: WhatsAppKeyState
    private let store: WhatsAppStore
    private var socket: WhatsAppSocket?
    private var waiters: [String: CheckedContinuation<WhatsAppNode, Error>] = [:]
    private let idPrefix = "\(UInt16.random(in: 0 ... .max)).\(UInt16.random(in: 0 ... .max))-"
    private var idCounter = 0
    private var onChanges: (@Sendable (WhatsAppChanges) -> Void)?
    private var onLoggedIn: (@Sendable () -> Void)?
    /// Logged in and the server has this device's prekeys, so the phone can open sessions with it and start the
    /// history sync. False again when the connection ends.
    private var isReady = false
    private var pending = WhatsAppChanges()
    private var mediaHosts: (hosts: [String], expires: Date)?
    /// Media retry requests waiting for the phone's `mediaretry` notification, by message id.
    private var mediaRetryWaiters: [String: CheckedContinuation<WhatsAppNode, Error>] = [:]
    /// On-demand history requests waiting for their sync, by chat; each gets how many messages came.
    private var historyWaiters: [String: [CheckedContinuation<Int, Never>]] = [:]
    private var lastHistoryRequest: Date?
    private var openChats = 0
    /// Retry receipts sent per message id.
    private var retryCounts: [String: Int] = [:]
    /// Resends per requesting device and message id.
    private var incomingRetryCounts: [String: Int] = [:]
    /// The newest messages sent from this device, so another device that couldn't decrypt one can get it again.
    private var recentSent: [String: (recipient: String, message: WhatsAppProto.Message)] = [:]
    private var recentSentOrder: [String] = []
    static let historyRequestSpacing: TimeInterval = 5
    /// Downloads in flight, so a file shown in several places downloads once.
    private var mediaDownloads: [String: Task<Data, Error>] = [:]
    private var syncingAppState = false
    private var avatarQueue: [String] = []
    /// The open chat that asked for a sender's picture, refreshed when it arrives.
    private var avatarRequesters: [String: String] = [:]
    private var avatarTask: Task<Void, Never>?

    @MainActor private static var clients: [String: WhatsAppClient] = [:]

    /// The account's one client. Its files have a single writer, so Settings (linking) and the live connection
    /// share it; two clients would each save their own copy of the chats over the other's.
    @MainActor public static func client(accountId: String, keychain: KeychainCredentialStore) -> WhatsAppClient {
        if let client = clients[accountId] { return client }
        let client = WhatsAppClient(keychain: keychain, accountId: accountId)
        clients[accountId] = client
        return client
    }

    @MainActor static func forget(accountId: String) {
        clients[accountId] = nil
    }

    private init(keychain: KeychainCredentialStore, accountId: String) {
        self.keychain = keychain
        store = WhatsAppStore(accountId: accountId)
        device = keychain.loadWhatsAppDevice().flatMap { try? JSONDecoder().decode(WhatsAppDevice.self, from: $0) }
        keys = Self.loadKeys(directory: store.directoryURL)
    }

    private static func loadKeys(directory: URL) -> WhatsAppKeyState {
        (try? Data(contentsOf: directory.appending(path: "keys.json"))).flatMap { try? JSONDecoder().decode(WhatsAppKeyState.self, from: $0) } ?? WhatsAppKeyState()
    }

    /// Picks up a link another client made for this account, such as the one Settings links with.
    private func reloadIfLinkedElsewhere() {
        guard device == nil, let data = keychain.loadWhatsAppDevice(), let linked = try? JSONDecoder().decode(WhatsAppDevice.self, from: data) else { return }
        device = linked
        keys = Self.loadKeys(directory: store.directoryURL)
        store.reload()
    }

    public nonisolated var isLinked: Bool {
        keychain.loadWhatsAppDevice() != nil
    }

    /// How far WhatsApp's sync got, for Settings.
    public var syncStatus: WhatsAppSyncStatus {
        WhatsAppSyncStatus(state: store.directory.sync, chatCount: store.chats.count)
    }

    public var account: WhatsAppAccount? {
        guard let jid = device?.jid else { return nil }
        return WhatsAppAccount(jid: jid, lid: device?.lid, pushName: device?.pushName)
    }

    private var signal: WhatsAppSignalStore {
        get {
            WhatsAppSignalStore(state: keys.signal, identity: device!.identityKey, registrationId: device!.registrationId, signedPreKey: device!.signedPreKey)
        }
        set {
            keys.signal = newValue.state
        }
    }

    private func saveDevice() {
        guard let device, let data = try? JSONEncoder().encode(device) else { return }
        try? keychain.saveWhatsAppDevice(data)
    }

    private func saveKeys() {
        try? FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: store.directoryURL.appending(path: "keys.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Requests

    private func requestId() -> String {
        idCounter += 1
        return "\(idPrefix)\(idCounter)"
    }

    private func send(_ node: WhatsAppNode) async throws {
        guard let socket else { throw WhatsAppError.notConnected }
        try await socket.send(node)
    }

    /// Sends a stanza and waits for the reply with its id: an `<iq>` result, or the `<ack>` for a message.
    private func request(_ node: WhatsAppNode, id: String, timeout: Duration = .seconds(60)) async throws -> WhatsAppNode {
        guard socket != nil else { throw WhatsAppError.notConnected }
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id: id, with: WhatsAppError.timeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            Task {
                do {
                    try await send(node)
                } catch {
                    fail(id: id, with: error)
                }
            }
        }
    }

    private func fail(id: String, with error: Error) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    @discardableResult
    private func iq(_ xmlns: String, _ type: String, to: WhatsAppJID = .server, target: WhatsAppJID? = nil, _ children: [WhatsAppNode] = [], timeout: Duration = .seconds(60)) async throws -> WhatsAppNode {
        let id = requestId()
        var node = WhatsAppNode("iq", ["id": .string(id), "xmlns": .string(xmlns), "type": .string(type), "to": .jid(to)], children: children)
        if let target {
            node["target"] = .jid(target)
        }
        if children.isEmpty {
            node.content = .none
        }
        let response = try await request(node, id: id, timeout: timeout)
        if response.attr("type") == "error" {
            let error = response.child("error")
            throw WhatsAppError.iq(code: error?.attr("code") ?? "", text: error?.attr("text") ?? "")
        }
        return response
    }

    private func ack(_ node: WhatsAppNode) async {
        var reply = WhatsAppNode("ack", ["class": .string(node.tag)])
        reply["id"] = node["id"]
        reply["to"] = node["from"]
        reply["participant"] = node["participant"]
        reply["recipient"] = node["recipient"]
        if node.tag != "message" {
            reply["type"] = node["type"]
        }
        try? await send(reply)
    }

    // MARK: Connection

    /// Opens a socket, runs the handshake and starts reading: replies resolve their requests, everything else
    /// arrives in order on the returned stream.
    private func open(payload: Data) async throws -> AsyncThrowingStream<WhatsAppNode, Error> {
        guard let device else { throw WhatsAppError.notLinked }
        let socket = WhatsAppSocket()
        try await socket.handshake(noiseKey: device.noiseKey, payload: payload)
        self.socket = socket
        let (stream, continuation) = AsyncThrowingStream<WhatsAppNode, Error>.makeStream()
        let reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let node = try await socket.receive()
                    guard let self else { return }
                    if await !resolve(node) {
                        continuation.yield(node)
                    }
                }
            } catch {
                continuation.finish(throwing: error)
                await self?.closed(socket, error: error)
            }
        }
        // whatsmeow sends keepalives from the moment it connects; WhatsApp drops a silent socket.
        let keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(Double.random(in: 20 ... 30)))
                _ = try? await self?.iq("w:p", "get", timeout: .seconds(10))
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            keepalive.cancel()
            socket.close()
        }
        return stream
    }

    private func resolve(_ node: WhatsAppNode) -> Bool {
        let isReply = (node.tag == "iq" && ["result", "error"].contains(node.attr("type") ?? "")) || node.tag == "ack"
        guard isReply, let id = node.attr("id"), let waiter = waiters.removeValue(forKey: id) else { return false }
        waiter.resume(returning: node)
        return true
    }

    private func closed(_ closedSocket: WhatsAppSocket, error _: Error) {
        guard socket === closedSocket else { return }
        socket = nil
        for waiter in waiters.values {
            waiter.resume(throwing: WhatsAppError.notConnected)
        }
        waiters.removeAll()
    }

    // MARK: Linking (whatsmeow pair.go, pair-code.go)

    /// Links a new device: shows QR codes, or with a number requests a pairing code, and returns once WhatsApp
    /// confirms the pairing. The first login happens on the next `run`.
    public func link(phoneNumber: String?, onUpdate: @escaping @Sendable (WhatsAppLinkUpdate) -> Void) async throws -> WhatsAppAccount {
        let version = try await Self.currentVersion()
        device = WhatsAppDevice.generate(version: version)
        keys = WhatsAppKeyState()
        let registration = WhatsAppProto.DevicePairingRegistrationData(
            registrationID: device!.registrationId, identityKey: device!.identityKey.publicKey, signedPreKeyID: device!.signedPreKey.id,
            signedPreKey: device!.signedPreKey.keyPair.publicKey, signedPreKeySignature: device!.signedPreKey.signature, deviceProps: WhatsAppProto.DeviceProps(),
        )
        let payload = WhatsAppProto.ClientPayload(version: device!.appVersion, mode: .registration(registration)).serialized()
        let stream = try await open(payload: payload)
        var pairing: (jid: WhatsAppJID, key: WhatsAppKeyPair, code: String, ref: Data)?
        var linked: WhatsAppAccount?
        var qrTask: Task<Void, Never>?
        defer {
            qrTask?.cancel()
            socket?.close()
            socket = nil
        }
        for try await node in stream {
            switch node.tag {
            case "iq" where node.jid("from") == .server:
                guard let child = node.children.first else { continue }
                if child.tag == "pair-device" {
                    var reply = WhatsAppNode("iq", ["type": "result"])
                    reply["to"] = node["from"]
                    reply["id"] = node["id"]
                    try await send(reply)
                    if let phoneNumber {
                        guard pairing == nil else { continue }
                        pairing = try await requestPairingCode(phoneNumber: phoneNumber)
                        onUpdate(.pairingCode(String(pairing!.code.prefix(4)) + "-" + String(pairing!.code.suffix(4))))
                    } else {
                        let refs = child.children.filter { $0.tag == "ref" }.compactMap { String(data: $0.bytes, encoding: .utf8) }
                        qrTask?.cancel()
                        qrTask = Task { [device] in
                            guard let device else { return }
                            for (index, ref) in refs.enumerated() {
                                let parts = [ref, device.noiseKey.publicKey.base64EncodedString(), device.identityKey.publicKey.base64EncodedString(), device.advSecret.base64EncodedString(), "6"]
                                onUpdate(.qr("https://wa.me/settings/linked_devices#" + parts.joined(separator: ",")))
                                try? await Task.sleep(for: .seconds(index == 0 ? 60 : 20))
                                if Task.isCancelled { return }
                            }
                        }
                    }
                } else if child.tag == "pair-success" {
                    qrTask?.cancel()
                    linked = try await pairSuccess(node, child)
                    onUpdate(.paired)
                }
            case "notification":
                await ack(node)
                if node.attr("type") == "link_code_companion_reg", let pairing {
                    try await finishPairingCode(node, pairing: pairing)
                }
            case "stream:error" where linked != nil:
                // WhatsApp closes the stream (515) once it has the signed identity; the link is complete.
                return linked!
            case "stream:error", "failure":
                throw WhatsAppError.pairingFailed
            default:
                break
            }
        }
        if let linked { return linked }
        throw WhatsAppError.linkExpired
    }

    private func requestPairingCode(phoneNumber: String) async throws -> (jid: WhatsAppJID, key: WhatsAppKeyPair, code: String, ref: Data) {
        let ephemeral = WhatsAppKeyPair.generate()
        let salt = WhatsAppCipher.randomBytes(32)
        let iv = WhatsAppCipher.randomBytes(16)
        let raw = WhatsAppCipher.randomBytes(5).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let code = String((0 ..< 8).map { Self.linkingAlphabet[Int(raw >> (35 - 5 * UInt64($0)) & 31)] })
        let key = WhatsAppCipher.pbkdf2SHA256(password: Data(code.utf8), salt: salt, iterations: 2 << 16, length: 32)
        let wrapped = try salt + iv + WhatsAppCipher.aesCTR(key: key, iv: iv, ephemeral.publicKey)
        let jid = WhatsAppJID(user: phoneNumber, server: WhatsAppJID.Server.user)
        var registration = WhatsAppNode("link_code_companion_reg", ["stage": "companion_hello", "should_show_push_notification": "true"], children: [
            WhatsAppNode("link_code_pairing_wrapped_companion_ephemeral_pub", bytes: wrapped),
            WhatsAppNode("companion_server_auth_key_pub", bytes: device!.noiseKey.publicKey),
            WhatsAppNode("companion_platform_id", content: .string("6")),
            // WhatsApp accepts only `Browser (OS)` with a common browser and OS; anything else is 400 bad-request.
            WhatsAppNode("companion_platform_display", content: .string("Safari (Mac OS)")),
            WhatsAppNode("link_code_pairing_nonce", bytes: Data([0])),
        ])
        registration["jid"] = .jid(jid)
        let response = try await iq("md", "set", [registration])
        guard let ref = response.child("link_code_companion_reg", "link_code_pairing_ref")?.bytes, !ref.isEmpty else { throw WhatsAppError.pairingFailed }
        return (jid, ephemeral, code, ref)
    }

    private func finishPairingCode(_ node: WhatsAppNode, pairing: (jid: WhatsAppJID, key: WhatsAppKeyPair, code: String, ref: Data)) async throws {
        guard let registration = node.child("link_code_companion_reg"), registration.child("link_code_pairing_ref")?.bytes == pairing.ref,
              let wrapped = registration.child("link_code_pairing_wrapped_primary_ephemeral_pub")?.bytes, wrapped.count >= 80,
              let primaryIdentity = registration.child("primary_identity_pub")?.bytes, var device
        else { throw WhatsAppError.pairingFailed }
        let start = wrapped.startIndex
        let key = WhatsAppCipher.pbkdf2SHA256(password: Data(pairing.code.utf8), salt: wrapped[start ..< start + 32], iterations: 2 << 16, length: 32)
        let primaryEphemeral = try WhatsAppCipher.aesCTR(key: key, iv: wrapped[start + 32 ..< start + 48], wrapped[start + 48 ..< start + 80])
        let ephemeralSecret = try pairing.key.agree(with: primaryEphemeral)
        let advRandom = WhatsAppCipher.randomBytes(32)
        let bundleSalt = WhatsAppCipher.randomBytes(32)
        let bundleNonce = WhatsAppCipher.randomBytes(12)
        let bundleKey = WhatsAppCipher.hkdf(ephemeralSecret, length: 32, salt: bundleSalt, info: Data("link_code_pairing_key_bundle_encryption_key".utf8))
        let bundle = try WhatsAppCipher.aesGCMSeal(key: bundleKey, nonce: bundleNonce, device.identityKey.publicKey + primaryIdentity + advRandom)
        let identitySecret = try device.identityKey.agree(with: primaryIdentity)
        device.advSecret = WhatsAppCipher.hkdf(ephemeralSecret + identitySecret + advRandom, length: 32, info: Data("adv_secret".utf8))
        self.device = device
        var finish = WhatsAppNode("link_code_companion_reg", ["stage": "companion_finish"], children: [
            WhatsAppNode("link_code_pairing_wrapped_key_bundle", bytes: bundleSalt + bundleNonce + bundle),
            WhatsAppNode("companion_identity_public", bytes: device.identityKey.publicKey),
            WhatsAppNode("link_code_pairing_ref", bytes: pairing.ref),
        ])
        finish["jid"] = .jid(pairing.jid)
        try await iq("md", "set", [finish])
    }

    private func pairSuccess(_ node: WhatsAppNode, _ success: WhatsAppNode) async throws -> WhatsAppAccount {
        guard var device, let requestId = node.attr("id") else { throw WhatsAppError.pairingFailed }
        let container = try WhatsAppProto.ADVSignedDeviceIdentityHMAC(data: success.child("device-identity")?.bytes ?? Data())
        let prefix = container.accountType == .hosted ? Data([6, 5]) : Data()
        guard WhatsAppCipher.hmacSHA256(key: device.advSecret, prefix + container.details) == container.hmac else {
            try? await pairError(requestId, code: 401, text: "hmac-mismatch")
            throw WhatsAppError.pairingFailed
        }
        var identity = try WhatsAppProto.ADVSignedDeviceIdentity(data: container.details)
        let details = try WhatsAppProto.ADVDeviceIdentity(data: identity.details ?? Data())
        let publicKey = device.identityKey.publicKey
        guard let accountKey = identity.accountSignatureKey, let accountSignature = identity.accountSignature,
              WhatsAppXEdDSA.verify(publicKey: accountKey, message: Data([6, 0]) + (identity.details ?? Data()) + publicKey, signature: accountSignature)
        else {
            try? await pairError(requestId, code: 401, text: "signature-mismatch")
            throw WhatsAppError.pairingFailed
        }
        identity.deviceSignature = device.identityKey.sign(Data([6, 1]) + (identity.details ?? Data()) + publicKey + accountKey)
        guard let jid = success.child("device")?.jid("jid") else { throw WhatsAppError.pairingFailed }
        let lid = success.child("device")?.jid("lid")
        device.jid = jid
        device.lid = lid
        device.account = identity.serialized()
        self.device = device
        if let lid {
            keys.signal.identities[WhatsAppJID(user: lid.user, server: WhatsAppJID.Server.lid).signalAddress] = accountKey
            store.update { $0.lidByPhoneNumber[jid.user] = lid.user }
        }
        saveDevice()
        saveKeys()
        store.save()
        identity.accountSignatureKey = nil
        var reply = WhatsAppNode("iq", ["type": "result", "id": .string(requestId)], children: [
            WhatsAppNode("pair-device-sign", children: [WhatsAppNode("device-identity", ["key-index": .string(String(details.keyIndex))], bytes: identity.serialized())]),
        ])
        reply["to"] = .jid(.server)
        try await send(reply)
        return WhatsAppAccount(jid: jid, lid: lid, pushName: nil)
    }

    private func pairError(_ id: String, code: Int, text: String) async throws {
        var reply = WhatsAppNode("iq", ["type": "error", "id": .string(id)], children: [WhatsAppNode("error", ["code": .string(String(code)), "text": .string(text)])])
        reply["to"] = .jid(.server)
        try await send(reply)
    }

    /// The current web client revision from `sw.js`, as Baileys reads it (needs `Sec-Fetch-Site`).
    static func currentVersion() async throws -> [UInt32] {
        var request = URLRequest(url: URL(string: "https://web.whatsapp.com/sw.js")!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        guard let match = body.firstMatch(of: /client_revision\\?":\s*(\d+)/), let revision = UInt32(match.1) else {
            throw WhatsAppError.clientOutdated
        }
        return [2, 3000, revision]
    }

    // MARK: Session

    /// Logs in and handles everything WhatsApp sends until the connection closes. `onLoggedIn` hears when the
    /// login succeeded, and `onChanges` what the store gained.
    public func run(onLoggedIn: @escaping @Sendable () -> Void, onChanges: @escaping @Sendable (WhatsAppChanges) -> Void) async throws {
        reloadIfLinkedElsewhere()
        guard let device, let jid = device.jid else { throw WhatsAppError.notLinked }
        self.onLoggedIn = onLoggedIn
        self.onChanges = onChanges
        let payload = WhatsAppProto.ClientPayload(version: device.appVersion, mode: .login(username: UInt64(jid.user) ?? 0, device: UInt32(jid.device))).serialized()
        let stream = try await open(payload: payload)
        logger.info("WhatsApp connected")
        defer {
            isReady = false
            socket?.close()
            socket = nil
            store.save()
            saveKeys()
        }
        for try await node in stream {
            try await handle(node)
            flush()
        }
        throw WhatsAppError.notConnected
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let changes = pending
        pending = WhatsAppChanges()
        store.save()
        onChanges?(changes)
    }

    private func handle(_ node: WhatsAppNode) async throws {
        switch node.tag {
        case "success":
            logger.info("WhatsApp logged in")
            onLoggedIn?()
            if let lid = node.jid("lid"), device?.lid == nil {
                device?.lid = lid
                saveDevice()
            }
            Task { await afterLogin() }
        case "failure":
            let reason = Int(node.attr("reason") ?? "") ?? 0
            switch reason {
            case 401, 403, 406:
                await forgetDevice()
                throw WhatsAppError.loggedOut
            case 402: throw WhatsAppError.banned
            case 405:
                if let version = try? await Self.currentVersion() {
                    device?.version = version
                    saveDevice()
                }
                throw WhatsAppError.clientOutdated
            default: throw WhatsAppError.connectFailure(reason)
            }
        case "stream:error":
            let code = node.attr("code") ?? ""
            let conflict = node.child("conflict")?.attr("type")
            if conflict == "device_removed" || code == "401" {
                await forgetDevice()
                throw WhatsAppError.loggedOut
            } else if conflict == "replaced" {
                throw WhatsAppError.replaced
            }
            throw WhatsAppError.streamError(code)
        case "message":
            await handleMessage(node)
        case "receipt":
            await ack(node)
            if node.attr("type") == "retry" {
                await handleRetryReceipt(node)
            } else {
                handleReceipt(node)
            }
        case "notification":
            await ack(node)
            await handleNotification(node)
        case "call":
            await ack(node)
        case "chatstate":
            // `<chatstate from=chat [participant=sender]><composing/>` or `<paused/>` (whatsmeow handleChatState).
            // The user's own typing comes back in their self chat, under their LID: it's never shown.
            if let from = node.jid("from"), let state = node.children.first?.tag,
               ![device?.jid?.user, device?.lid?.user].contains((node.jid("participant") ?? from).user)
            {
                let sender = (node.jid("participant") ?? from).nonAD.description
                pending.typing.append(WhatsAppTyping(chat: canonicalChat(from.nonAD), sender: sender, isTyping: state == "composing"))
            }
        default:
            break
        }
    }

    /// Waits until a connection has logged in and uploaded this device's prekeys, or `timeout` passed; returns
    /// whether it did. Linking waits for this before it ends, so the phone can reach the new device.
    public func waitUntilReady(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isReady, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return isReady
    }

    private func afterLogin() async {
        do {
            try await ensurePreKeys()
            isReady = true
            try await iq("passive", "set", [WhatsAppNode("active")])
            if let privacy = try? await iq("privacy", "get", [WhatsAppNode("privacy")]) {
                let category = privacy.child("privacy")?.children.first { $0.attr("name") == "readreceipts" }
                keys.readReceipts = category?.attr("value") != "none"
            }
            if !keys.appStateKeys.isEmpty {
                await syncAppState()
            }
            try await fetchGroups()
            requestAvatars(for: store.chats.sorted { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }.prefix(Self.avatarPrefetchCount).map(\.jid))
        } catch {
            logger.info("WhatsApp post-login setup failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func forgetDevice() async {
        device = nil
        try? keychain.deleteWhatsAppDevice()
    }

    /// Logs this device out of WhatsApp (connecting for it when the app isn't) and removes its keys and chats.
    public func logout() async {
        if let jid = device?.jid {
            // Kept until the request is answered: ending the stream closes its socket.
            var iterator: AsyncThrowingStream<WhatsAppNode, Error>.AsyncIterator?
            if socket == nil, let device {
                let payload = WhatsAppProto.ClientPayload(version: device.appVersion, mode: .login(username: UInt64(jid.user) ?? 0, device: UInt32(jid.device))).serialized()
                iterator = try? await open(payload: payload).makeAsyncIterator()
                while let node = try? await iterator?.next(), node.tag != "success", node.tag != "failure" {}
            }
            _ = try? await iq("md", "set", [WhatsAppNode("remove-companion-device", ["jid": .jid(jid), "reason": "user_initiated"])])
            iterator = nil
        }
        socket?.close()
        socket = nil
        await forgetDevice()
        keys = WhatsAppKeyState()
        store.removeAll()
    }

    // MARK: Prekeys (whatsmeow prekeys.go)

    private func ensurePreKeys() async throws {
        guard let device else { return }
        let response = try await iq("encrypt", "get", [WhatsAppNode("count")])
        let count = Int(response.child("count")?.attr("value") ?? "") ?? 0
        guard count < Self.minimumPreKeyCount || keys.uploadedPreKeyId == 0 else { return }
        let wanted = count == 0 && keys.uploadedPreKeyId == 0 ? Self.initialPreKeyCount : Self.wantedPreKeyCount
        var nodes: [WhatsAppNode] = []
        for _ in 0 ..< wanted {
            let id = keys.nextPreKeyId
            keys.nextPreKeyId += 1
            let pair = WhatsAppKeyPair.generate()
            keys.preKeys[String(id)] = pair
            nodes.append(WhatsAppNode("key", children: [WhatsAppNode("id", bytes: Self.uint24(id)), WhatsAppNode("value", bytes: pair.publicKey)]))
        }
        saveKeys()
        try await iq("encrypt", "set", [
            WhatsAppNode("registration", bytes: withUnsafeBytes(of: device.registrationId.bigEndian) { Data($0) }),
            WhatsAppNode("type", bytes: Data([5])),
            WhatsAppNode("identity", bytes: device.identityKey.publicKey),
            WhatsAppNode("list", children: nodes),
            WhatsAppNode("skey", children: [
                WhatsAppNode("id", bytes: Self.uint24(device.signedPreKey.id)),
                WhatsAppNode("value", bytes: device.signedPreKey.keyPair.publicKey),
                WhatsAppNode("signature", bytes: device.signedPreKey.signature),
            ]),
        ])
        keys.uploadedPreKeyId = keys.nextPreKeyId - 1
        saveKeys()
    }

    private static func uint24(_ value: UInt32) -> Data {
        Data([UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    // MARK: Addressing

    private var ownUsers: Set<String> {
        Set([device?.jid?.user, device?.lid?.user].compactMap(\.self))
    }

    private func lid(for jid: WhatsAppJID) -> WhatsAppJID? {
        if jid.server == WhatsAppJID.Server.lid { return jid }
        return store.lid(forPhoneNumberUser: jid.user).map { WhatsAppJID(user: $0, server: WhatsAppJID.Server.lid, device: jid.device) }
    }

    private func storeLID(phoneNumber: WhatsAppJID?, lid: WhatsAppJID?) {
        guard let phoneNumber, let lid, phoneNumber.server == WhatsAppJID.Server.user, lid.server == WhatsAppJID.Server.lid,
              store.lid(forPhoneNumberUser: phoneNumber.user) != lid.user
        else { return }
        store.update { $0.lidByPhoneNumber[phoneNumber.user] = lid.user }
    }

    /// One chat per person: a LID chat and a phone-number chat for the same person are the one history named.
    private func canonicalChat(_ jid: WhatsAppJID) -> String {
        let plain = jid.nonAD
        if plain.server == WhatsAppJID.Server.lid, let phone = store.phoneNumberUser(forLIDUser: plain.user) {
            let phoneChat = "\(phone)@\(WhatsAppJID.Server.user)"
            if store.chat(phoneChat) != nil { return phoneChat }
        } else if plain.server == WhatsAppJID.Server.user, let lid = store.lid(forPhoneNumberUser: plain.user) {
            let lidChat = "\(lid)@\(WhatsAppJID.Server.lid)"
            if store.chat(lidChat) != nil { return lidChat }
        }
        return plain.description
    }

    // MARK: Receiving (whatsmeow message.go)

    private struct Source {
        var chat: WhatsAppJID
        var sender: WhatsAppJID
        var senderAlt: WhatsAppJID?
        var isGroup: Bool
        var isFromMe: Bool
    }

    private func source(of node: WhatsAppNode) -> Source? {
        guard let from = node.jid("from") else { return nil }
        let own = ownUsers
        if from.server == WhatsAppJID.Server.group || from.server == WhatsAppJID.Server.broadcast {
            guard let participant = node.jid("participant") else { return nil }
            let alt = node.jid("participant_pn") ?? (node.attr("addressing_mode") != "lid" ? node.jid("participant_lid") : nil)
            return Source(chat: from, sender: participant, senderAlt: alt, isGroup: true, isFromMe: own.contains(participant.user))
        } else if own.contains(from.user) {
            return Source(chat: node.jid("recipient") ?? from.nonAD, sender: from, senderAlt: nil, isGroup: false, isFromMe: true)
        }
        let alt = from.server == WhatsAppJID.Server.lid ? node.jid("sender_pn") : node.jid("sender_lid")
        return Source(chat: from.nonAD, sender: from, senderAlt: alt, isGroup: false, isFromMe: false)
    }

    private func encryptionJID(_ source: Source) -> WhatsAppJID {
        var alt = source.senderAlt
        if let value = alt, value.device == 0 {
            alt = WhatsAppJID(user: value.user, server: value.server, device: source.sender.device)
        }
        if source.sender.server == WhatsAppJID.Server.user {
            if let alt, alt.server == WhatsAppJID.Server.lid {
                storeLID(phoneNumber: source.sender, lid: alt)
                return alt
            }
            return lid(for: source.sender) ?? source.sender
        }
        if source.sender.server == WhatsAppJID.Server.lid, let alt, alt.server == WhatsAppJID.Server.user {
            storeLID(phoneNumber: alt, lid: source.sender)
        }
        return source.sender
    }

    private func handleMessage(_ node: WhatsAppNode) async {
        guard let source = source(of: node), let id = node.attr("id") else {
            await ack(node)
            return
        }
        if let notify = node.attr("notify"), !notify.isEmpty, notify != "-" {
            store.update { $0.pushNames[source.sender.user] = notify }
        }
        let address = encryptionJID(source)
        let timestamp = Date(timeIntervalSince1970: TimeInterval(node.attr("t").flatMap(Double.init) ?? Date().timeIntervalSince1970))
        var decryptedAny = false
        for child in node.children where child.tag == "enc" {
            let content = child.bytes
            do {
                var store = signal
                let plaintext: Data
                switch child.attr("type") {
                case "pkmsg":
                    let result = try store.decryptPreKeyMessage(address: address.signalAddress, content, keepState: child.attr("state") != "false") { id in
                        self.keys.preKeys[String(id)]
                    }
                    if child.attr("state") != "false", let used = result.usedPreKeyId {
                        keys.preKeys[String(used)] = nil
                    }
                    plaintext = result.plaintext
                case "msg":
                    plaintext = try store.decryptMessage(address: address.signalAddress, content)
                case "skmsg" where source.isGroup:
                    plaintext = try store.decryptGroupMessage(group: source.chat.description, address: address.signalAddress, content)
                default:
                    continue
                }
                signal = store
                saveKeys()
                let version = Int(child.attr("v") ?? "2") ?? 2
                guard version == 2 else { continue }
                let message = try WhatsAppProto.Message(data: WhatsAppMessagePadding.unpad(plaintext, version: version))
                decryptedAny = true
                await handleDecrypted(message, id: id, source: source, address: address, timestamp: timestamp, node: node)
            } catch WhatsAppSignalError.oldCounter {
                continue
            } catch {
                logger.info("WhatsApp couldn't decrypt \(child.attr("type") ?? "", privacy: .public): \(String(describing: error), privacy: .public)")
                AppMetrics.whatsAppFailed("decrypt", error: error)
                await sendRetryReceipt(for: node, id: id, source: source)
                await ack(node)
                return
            }
        }
        if decryptedAny {
            var receipt = WhatsAppNode("receipt", ["id": .string(id)])
            receipt["to"] = node["from"]
            receipt["recipient"] = node["recipient"]
            receipt["participant"] = node["participant"]
            // Like whatsmeow without active receipts: delivered to an inactive device, never "read".
            receipt["type"] = source.isFromMe ? (node.attr("type") == "peer_msg" ? "peer_msg" : "sender") : "inactive"
            try? await send(receipt)
        } else {
            await ack(node)
        }
    }

    private func handleDecrypted(_ message: WhatsAppProto.Message, id: String, source: Source, address: WhatsAppJID, timestamp: Date, node: WhatsAppNode) async {
        var content = message
        var chat = source.chat
        if let deviceSent = message.deviceSent, let inner = deviceSent.message {
            content = inner
            if let destination = deviceSent.destinationJID.flatMap(WhatsAppJID.init(string:)) {
                chat = destination
            }
        }
        if let distribution = content.senderKeyDistribution?.axolotlSenderKeyDistributionMessage, source.isGroup {
            var store = signal
            if (try? store.processSenderKeyDistribution(group: source.chat.description, address: address.signalAddress, distribution)) != nil {
                signal = store
                saveKeys()
            }
        }
        if let protocolMessage = content.protocolMessage {
            await handleProtocolMessage(protocolMessage, id: id, source: source, chat: chat, timestamp: timestamp, node: node)
        }
        // Status updates (`status@broadcast`) and broadcast lists aren't chats.
        guard chat.server != WhatsAppJID.Server.broadcast else { return }
        apply(content, id: id, chat: canonicalChat(chat), sender: source.isFromMe ? (device?.jid?.nonAD.description ?? "") : source.sender.nonAD.description, isFromMe: source.isFromMe, timestamp: timestamp, live: true)
    }

    private func handleProtocolMessage(_ message: WhatsAppProto.ProtocolMessage, id: String, source: Source, chat _: WhatsAppJID, timestamp _: Date, node: WhatsAppNode) async {
        guard source.isFromMe else { return }
        if let notification = message.historySyncNotification {
            do {
                try await processHistorySync(notification)
            } catch {
                logger.info("WhatsApp history sync failed: \(String(describing: error), privacy: .public)")
                AppMetrics.whatsAppFailed("history_sync", error: error)
            }
            if let own = device?.jid?.nonAD {
                try? await send(WhatsAppNode("receipt", ["id": .string(id), "type": "hist_sync", "to": .jid(own)]))
            }
        }
        if let share = message.appStateSyncKeyShare {
            for key in share.keys {
                guard let keyId = key.keyID, let data = key.keyData else { continue }
                keys.appStateKeys[keyId.hexString] = .init(data: data, timestamp: key.timestamp ?? 0)
            }
            saveKeys()
            Task { await syncAppState() }
        }
        if let payload = message.lidMigrationMappingPayload, let mappings = try? WhatsAppProto.LIDMigrationMappingSyncPayload(data: payload) {
            store.update { directory in
                for mapping in mappings.mappings {
                    directory.lidByPhoneNumber[String(mapping.pn)] = String(mapping.assignedLID)
                }
            }
        }
        for data in message.resentMessages {
            guard let info = try? WhatsAppProto.WebMessageInfo(data: data), let key = info.key, let id = key.id,
                  let remote = key.remoteJID.flatMap(WhatsAppJID.init(string:)), let content = info.message else { continue }
            let own = device?.jid?.nonAD.description ?? ""
            let sender = key.fromMe == true ? own : (key.participant ?? info.participant ?? remote.description)
            apply(content, id: id, chat: canonicalChat(remote), sender: WhatsAppJID(string: sender)?.nonAD.description ?? sender, isFromMe: key.fromMe == true,
                  timestamp: Date(timeIntervalSince1970: TimeInterval(info.messageTimestamp)), live: true)
        }
        if node.attr("category") == "peer", let own = device?.jid?.nonAD {
            try? await send(WhatsAppNode("receipt", ["id": .string(id), "type": "peer_msg", "to": .jid(own)]))
        }
    }

    /// Stores a message's effect: a new or edited message, a deletion, or nothing for protocol-only content.
    private func apply(_ message: WhatsAppProto.Message, id: String, chat: String, sender: String, isFromMe: Bool, timestamp: Date, live: Bool, reactions: [String: String] = [:]) {
        let content = message.unwrapped
        if let reaction = content.reaction, let target = reaction.key?.id {
            // A reaction belongs to the message it reacts to; an empty one takes the reactor's back.
            let emoji = reaction.text ?? ""
            if store.modifyMessage(target, in: chat, { $0.reactions[sender] = emoji.isEmpty ? nil : emoji }) {
                pending.chats.insert(chat)
            }
            return
        }
        if let protocolMessage = content.protocolMessage {
            switch protocolMessage.kind {
            case .revoke:
                if let target = protocolMessage.key?.id, store.modifyMessage(target, in: chat, { $0.isDeleted = true; $0.text = nil; $0.label = nil }) {
                    pending.chats.insert(chat)
                }
            case .messageEdit:
                if let target = protocolMessage.key?.id, let edited = protocolMessage.editedMessage,
                   store.modifyMessage(target, in: chat, { $0.text = Self.text(of: edited.unwrapped) ?? $0.text; $0.editedAt = timestamp })
                {
                    pending.chats.insert(chat)
                }
            default:
                break
            }
            return
        }
        if content.reaction != nil || content.senderKeyDistribution != nil, Self.text(of: content) == nil, Self.label(of: content) == nil {
            return
        }
        let text = Self.text(of: content)
        let label = text == nil ? Self.label(of: content) ?? "Unsupported message" : nil
        let context = content.extendedText?.contextInfo ?? content.media?.contextInfo
        let quotedSender = context?.participant.flatMap { WhatsAppJID(string: $0)?.nonAD.description }
        let stored = WhatsAppMessage(id: id, sender: sender, isFromMe: isFromMe, timestamp: timestamp, text: text, label: label, quotedId: context?.stanzaID,
                                     reactions: reactions, media: content.media.map(Self.media), quotedSender: quotedSender)
        if store.upsert([stored], in: chat), live {
            store.updateChat(chat) { chat in
                if isFromMe {
                    // Writing from another device reads the chat there.
                    chat.unreadCount = 0
                    chat.readUpTo = timestamp
                } else if chat.readUpTo == nil {
                    chat.unreadCount += 1
                }
            }
        }
        pending.chats.insert(chat)
    }

    static func media(_ media: WhatsAppProto.MediaMessage) -> WhatsAppMedia {
        let kind: WhatsAppMedia.Kind = switch media.kind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .document: .document
        case .sticker: .sticker
        }
        return WhatsAppMedia(
            kind: kind, mimetype: media.mimetype, directPath: media.directPath, mediaKey: media.mediaKey,
            fileEncSHA256: media.fileEncSHA256, fileSHA256: media.fileSHA256, fileLength: media.fileLength,
            width: media.width, height: media.height, seconds: media.seconds, isVoice: media.ptt == true,
            isAnimated: media.isAnimated == true, fileName: media.fileName, waveform: media.waveform, thumbnail: media.jpegThumbnail,
        )
    }

    static func text(of message: WhatsAppProto.Message) -> String? {
        let text = message.conversation ?? message.extendedText?.text ?? message.media?.caption
        return text?.isEmpty == false ? text : nil
    }

    static func label(of message: WhatsAppProto.Message) -> String? {
        if let media = message.media {
            switch media.kind {
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return media.ptt == true ? "Voice message" : "Audio"
            case .document: return media.fileName.map { "Document: \($0)" } ?? "Document"
            case .sticker: return "Sticker"
            }
        }
        if message.contact != nil || message.contactsArray != nil { return "Contact" }
        if let location = message.location { return location.isLive ? "Live location" : "Location" }
        if let poll = message.poll { return poll.name.map { "Poll: \($0)" } ?? "Poll" }
        return nil
    }

    private func handleReceipt(_ node: WhatsAppNode) {
        // The user read messages on another of their devices.
        guard node.attr("type") == "read-self", let from = node.jid("from") else { return }
        let chat = canonicalChat(node.jid("recipient") ?? from)
        let time = node.attr("t").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
        store.updateChat(chat) {
            $0.readUpTo = max($0.readUpTo ?? .distantPast, time)
            $0.unreadCount = 0
        }
        pending.chats.insert(chat)
    }

    private func handleNotification(_ node: WhatsAppNode) async {
        switch node.attr("type") {
        case "encrypt" where node.jid("from") == .server:
            if let count = node.child("count")?.attr("value").flatMap(Int.init), count < Self.minimumPreKeyCount {
                try? await ensurePreKeys()
            }
        case "server_sync":
            await syncAppState()
        case "w:gp2":
            try? await fetchGroups()
        case "privacy_token":
            if let sender = node.jid("sender_lid") ?? node.jid("from") {
                for token in node.child("tokens")?.children ?? [] where token.tag == "token" && token.attr("type") == "trusted_contact" {
                    storePrivacyToken(for: sender, token: token.bytes, timestamp: token.attr("t").flatMap(Int64.init) ?? 0, senderTimestamp: nil)
                }
                saveKeys()
            }
        case "mediaretry":
            if let id = node.attr("id"), let waiter = mediaRetryWaiters.removeValue(forKey: id) {
                waiter.resume(returning: node)
            }
        case "picture":
            // Someone changed their picture: look it up again when it's next shown.
            for child in node.children {
                if let jid = child.jid("jid") ?? node.jid("from") {
                    store.update { $0.avatars[jid.nonAD.description] = nil }
                }
            }
        default:
            break
        }
    }

    // MARK: History sync

    private func processHistorySync(_ notification: WhatsAppProto.HistorySyncNotification) async throws {
        let compressed: Data = if let inline = notification.initialHistBootstrapInlinePayload, !inline.isEmpty {
            inline
        } else {
            try await download(directPath: notification.directPath, encSHA256: notification.fileEncSHA256, sha256: notification.fileSHA256, mediaKey: notification.mediaKey, info: "WhatsApp History Keys", mmsType: "md-msg-hist")
        }
        let history = try WhatsAppProto.HistorySync(data: WhatsAppZlib.decompress(compressed))
        store.update { directory in
            for mapping in history.phoneNumberToLIDMappings {
                if let phone = WhatsAppJID(string: mapping.pnJID), let lid = WhatsAppJID(string: mapping.lidJID) {
                    directory.lidByPhoneNumber[phone.user] = lid.user
                }
            }
            for pushName in history.pushnames {
                if let jid = WhatsAppJID(string: pushName.id) {
                    directory.pushNames[jid.user] = pushName.pushname
                }
            }
            var sync = directory.sync ?? WhatsAppSyncState()
            sync.received(history.syncType, progress: history.progress)
            directory.sync = sync
        }
        let own = device?.jid?.nonAD.description ?? ""
        // An on-demand sync answers a request for one chat's older messages: it carries only them, so it leaves
        // the chat's unread count, archive, mute and the rest as they are.
        let isOnDemand = history.syncType == .onDemand
        var delivered: [String: Int] = [:]
        for conversation in history.conversations {
            guard let jid = WhatsAppJID(string: conversation.id), jid.server != WhatsAppJID.Server.broadcast, jid.server != WhatsAppJID.Server.newsletter else { continue }
            let chat = jid.description
            delivered[chat, default: 0] += conversation.messages.count
            if let token = conversation.tcToken, !token.isEmpty {
                storePrivacyToken(for: jid, token: token, timestamp: Int64(conversation.tcTokenTimestamp), senderTimestamp: Int64(conversation.tcTokenSenderTimestamp))
            }
            if !isOnDemand { store.updateChat(chat) { stored in
                if let name = conversation.name, !name.isEmpty { stored.name = name }
                if let phone = conversation.pnJID { stored.phoneNumberJID = phone }
                stored.unreadCount = Int(conversation.unreadCount)
                stored.markedUnread = conversation.markedAsUnread
                stored.isArchived = conversation.archived
                stored.isPinned = conversation.pinned > 0
                stored.muteEnd = conversation.muteEndTime > 0 ? Int64(bitPattern: conversation.muteEndTime) : nil
                stored.readUpTo = nil
                let time = Date(timeIntervalSince1970: TimeInterval(max(conversation.conversationTimestamp, conversation.lastMsgTimestamp)))
                if time > (stored.lastTimestamp ?? .distantPast) { stored.lastTimestamp = time }
            } }
            for info in conversation.messages {
                guard let message = info.message, let key = info.key, let id = key.id else { continue }
                let isFromMe = key.fromMe == true
                let sender = isFromMe ? own : (key.participant ?? info.participant ?? key.remoteJID ?? chat)
                var reactions: [String: String] = [:]
                for reaction in info.reactions {
                    guard let emoji = reaction.text, !emoji.isEmpty, let reactionKey = reaction.key else { continue }
                    let reactor = reactionKey.fromMe == true ? own : (reactionKey.participant ?? reactionKey.remoteJID ?? chat)
                    reactions[WhatsAppJID(string: reactor)?.nonAD.description ?? reactor] = emoji
                }
                apply(message, id: id, chat: chat, sender: WhatsAppJID(string: sender)?.nonAD.description ?? sender, isFromMe: isFromMe,
                      timestamp: Date(timeIntervalSince1970: TimeInterval(info.messageTimestamp)), live: false, reactions: reactions)
            }
        }
        if isOnDemand {
            for (chat, count) in delivered {
                pending.chats.insert(canonicalChat(WhatsAppJID(string: chat) ?? .server))
                for waiter in historyWaiters.removeValue(forKey: chat) ?? [] {
                    waiter.resume(returning: count)
                }
            }
        } else {
            pending.reloadList = true
        }
        logger.info("WhatsApp history sync: \(history.conversations.count) chats")
    }

    private func download(directPath: String?, encSHA256: Data?, sha256: Data?, mediaKey: Data?, info: String, mmsType: String) async throws -> Data {
        guard let directPath, let encSHA256, let sha256, let mediaKey else { throw WhatsAppError.download }
        if mediaHosts == nil || mediaHosts!.expires < Date() {
            let response = try await iq("w:m", "set", [WhatsAppNode("media_conn")])
            let connection = response.child("media_conn")
            let hosts = connection?.children.filter { $0.tag == "host" }.compactMap { $0.attr("hostname") } ?? []
            let ttl = connection?.attr("ttl").flatMap(Double.init) ?? 300
            mediaHosts = (hosts, Date().addingTimeInterval(ttl))
        }
        let expanded = WhatsAppCipher.hkdf(mediaKey, length: 112, info: Data(info.utf8))
        let iv = expanded.prefix(16)
        let cipherKey = expanded[expanded.startIndex + 16 ..< expanded.startIndex + 48]
        let macKey = expanded[expanded.startIndex + 48 ..< expanded.startIndex + 80]
        let hash = encSHA256.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        var expired = false
        for host in mediaHosts?.hosts ?? [] {
            guard let url = URL(string: "https://\(host)\(directPath)&hash=\(hash)&mms-type=\(mmsType)&__wa-mms=") else { continue }
            var request = URLRequest(url: url)
            request.setValue(WhatsAppSocket.origin, forHTTPHeaderField: "Origin")
            request.setValue(WhatsAppSocket.origin + "/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [403, 404, 410].contains(status) {
                expired = true
                continue
            }
            guard status == 200, data.count > 10 else { continue }
            guard WhatsAppCipher.sha256(data) == encSHA256 else { throw WhatsAppError.download }
            let file = data.prefix(data.count - 10)
            guard WhatsAppCipher.hmacSHA256(key: Data(macKey), Data(iv) + file).prefix(10) == data.suffix(10) else { throw WhatsAppError.download }
            let plaintext = try WhatsAppCipher.aesCBCDecrypt(key: Data(cipherKey), iv: Data(iv), Data(file))
            guard WhatsAppCipher.sha256(plaintext) == sha256 else { throw WhatsAppError.download }
            return plaintext
        }
        throw expired ? WhatsAppError.mediaExpired : WhatsAppError.download
    }

    // MARK: Privacy tokens (whatsmeow tctoken.go; validated with the probe's `send`, 2026-11-22)

    static let tokenBucket: Int64 = 604_800

    /// Tokens older than three weekly buckets before this one have expired.
    static var tokenCutoff: Int64 {
        (Int64(Date().timeIntervalSince1970) / tokenBucket - 3) * tokenBucket
    }

    /// Stored by LID user, as whatsmeow prefers; a phone-number JID is mapped when its LID is known.
    private func tokenUser(_ jid: WhatsAppJID) -> String {
        jid.server == WhatsAppJID.Server.user ? (lid(for: jid.nonAD)?.user ?? jid.user) : jid.user
    }

    private func storePrivacyToken(for jid: WhatsAppJID, token: Data, timestamp: Int64, senderTimestamp: Int64?) {
        let user = tokenUser(jid)
        var tokens = keys.privacyTokens ?? [:]
        let previous = tokens[user]
        guard (previous?.timestamp ?? 0) <= timestamp || previous?.token == nil else { return }
        tokens[user] = .init(token: token, timestamp: timestamp, senderTimestamp: senderTimestamp ?? previous?.senderTimestamp ?? 0)
        keys.privacyTokens = tokens
    }

    /// `<tctoken>` with the contact's unexpired token, for 1:1 sends, presence subscriptions and pictures.
    private func privacyTokenNode(for jid: WhatsAppJID) -> WhatsAppNode? {
        guard let stored = keys.privacyTokens?[tokenUser(jid)], let token = stored.token, !token.isEmpty, stored.timestamp >= Self.tokenCutoff else { return nil }
        return WhatsAppNode("tctoken", bytes: token)
    }

    /// After a 1:1 send, our own token goes to the recipient once per weekly bucket (`issuePrivacyTokenAndSave`).
    private func issuePrivacyTokenIfNeeded(to jid: WhatsAppJID) async {
        let user = tokenUser(jid)
        let now = Int64(Date().timeIntervalSince1970)
        let sent = keys.privacyTokens?[user]?.senderTimestamp ?? 0
        guard sent == 0 || now / Self.tokenBucket > sent / Self.tokenBucket else { return }
        var token = WhatsAppNode("token", ["t": .string(String(now)), "type": "trusted_contact"])
        token["jid"] = .jid(WhatsAppJID(user: user, server: WhatsAppJID.Server.lid))
        do {
            _ = try await iq("privacy", "set", [WhatsAppNode("tokens", children: [token])])
            var tokens = keys.privacyTokens ?? [:]
            tokens[user, default: .init(token: nil, timestamp: 0, senderTimestamp: 0)].senderTimestamp = now
            keys.privacyTokens = tokens
            saveKeys()
        } catch {
            logger.info("WhatsApp privacy token issue failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: History on demand (whatsmeow BuildHistorySyncRequest, SendPeerMessage)

    /// Asks the phone for up to `count` messages before `before` in a chat and waits for them (up to 30 s);
    /// returns how many came. The phone answers with an on-demand history sync, which stores them like any other
    /// (validated with the probe's `history`, 2026-11-22).
    public func requestHistory(chat: String, before message: WhatsAppMessage, count: Int = 50) async throws -> Int {
        // At most one request every few seconds, however fast a chat pages back, so the phone isn't flooded.
        if let last = lastHistoryRequest, Date().timeIntervalSince(last) < Self.historyRequestSpacing {
            try await Task.sleep(for: .seconds(Self.historyRequestSpacing - Date().timeIntervalSince(last)))
        }
        lastHistoryRequest = Date()
        // The phone keys chats as history sync names them: a phone-number chat for people it knows by number.
        let requestChat = chat
        var request = ProtoMessage()
        request.set(1, requestChat)
        request.set(2, message.id)
        request.set(3, message.isFromMe)
        request.set(4, Int32(count))
        // Seconds, despite the name (whatsmeow).
        request.set(5, Int64(message.timestamp.timeIntervalSince1970))
        var operation = ProtoMessage()
        operation.set(1, UInt64(3)) // HISTORY_SYNC_ON_DEMAND
        operation.set(4, request)
        var protocolMessage = ProtoMessage()
        protocolMessage.set(2, UInt64(16)) // PEER_DATA_OPERATION_REQUEST_MESSAGE
        protocolMessage.set(16, operation)
        var wrapper = ProtoMessage()
        wrapper.set(WhatsAppProto.Message.Field.protocolMessage, protocolMessage)
        return await withCheckedContinuation { continuation in
            historyWaiters[requestChat, default: []].append(continuation)
            Task {
                do {
                    try await sendPeer(wrapper, historyRequest: true)
                } catch {
                    logger.info("WhatsApp history request failed: \(String(describing: error), privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(30))
                for waiter in historyWaiters.removeValue(forKey: requestChat) ?? [] {
                    waiter.resume(returning: 0)
                }
            }
        }
    }

    /// A protocol message to the user's own phone only (`category="peer"`); history requests go with
    /// `push_priority="high_force"` and `privacy_sensitive`, as whatsmeow's `preparePeerMessageNode` sends them.
    private func sendPeer(_ message: ProtoMessage, historyRequest: Bool) async throws {
        guard let own = device?.jid?.nonAD, let ownLID = device?.lid, let account = device?.account else { throw WhatsAppError.notLinked }
        let phone = WhatsAppJID(user: ownLID.user, server: WhatsAppJID.Server.lid)
        var store = signal
        if !store.hasSession(address: phone.signalAddress) {
            for (address, bundle) in try await bundles(for: [phone]) {
                try? store.buildSession(address: address, bundle: bundle)
            }
        }
        let encrypted = try store.encrypt(address: phone.signalAddress, WhatsAppMessagePadding.pad(message.serialized()))
        signal = store
        saveKeys()
        let id = messageId()
        var children = [WhatsAppNode("meta", ["appdata": "default"]), WhatsAppNode("enc", ["v": "2", "type": .string(encrypted.type.rawValue)], bytes: encrypted.data)]
        if encrypted.type == .pkmsg {
            children.append(WhatsAppNode("device-identity", bytes: account))
        }
        var node = WhatsAppNode("message", ["id": .string(id), "type": "text", "category": "peer"], children: children)
        if historyRequest {
            node["push_priority"] = "high_force"
            node["privacy_sensitive"] = "1"
        }
        node["to"] = .jid(own)
        let ack = try await request(node, id: id)
        if let error = ack.attr("error") {
            throw WhatsAppError.sendFailed(error)
        }
    }

    // MARK: Media (whatsmeow download.go, mediaretry.go)

    /// A message's file, decrypted. An expired file is asked of the phone once (a media retry, as WhatsApp Web
    /// does when an old photo is opened), and the new path is kept with the message.
    public func downloadMedia(chat: String, messageId: String) async throws -> Data {
        let key = "\(chat)/\(messageId)"
        if let running = mediaDownloads[key] {
            return try await running.value
        }
        let task = Task { try await self.loadMedia(chat: chat, messageId: messageId) }
        mediaDownloads[key] = task
        defer { mediaDownloads[key] = nil }
        return try await task.value
    }

    /// The message's inline JPEG preview.
    public func mediaThumbnail(chat: String, messageId: String) throws -> Data {
        guard let thumbnail = store.messages(in: chat).first(where: { $0.id == messageId })?.media?.thumbnail, !thumbnail.isEmpty else { throw WhatsAppError.mediaUnavailable }
        return thumbnail
    }

    private func loadMedia(chat: String, messageId: String) async throws -> Data {
        guard let message = store.messages(in: chat).first(where: { $0.id == messageId }), let media = message.media else { throw WhatsAppError.unsupported }
        guard media.isDownloadable else { throw WhatsAppError.mediaUnavailable }
        do {
            return try await download(directPath: media.directPath, encSHA256: media.fileEncSHA256, sha256: media.fileSHA256, mediaKey: media.mediaKey, info: media.kind.keyInfo, mmsType: media.kind.mmsType)
        } catch WhatsAppError.mediaExpired {
            let directPath = try await requestMediaRetry(chat: chat, message: message, mediaKey: media.mediaKey ?? Data())
            _ = store.modifyMessage(messageId, in: chat) { $0.media?.directPath = directPath }
            store.save()
            return try await download(directPath: directPath, encSHA256: media.fileEncSHA256, sha256: media.fileSHA256, mediaKey: media.mediaKey, info: media.kind.keyInfo, mmsType: media.kind.mmsType)
        }
    }

    /// Asks the phone to upload the message's file again (whatsmeow `SendMediaRetryReceipt`) and returns the new
    /// path from its encrypted `mediaretry` notification (validated with the probe's `media --retry`, 2026-11-22).
    private func requestMediaRetry(chat: String, message: WhatsAppMessage, mediaKey: Data) async throws -> String {
        guard let own = device?.jid?.nonAD, let chatJID = WhatsAppJID(string: chat) else { throw WhatsAppError.notLinked }
        let key = WhatsAppCipher.hkdf(mediaKey, length: 32, info: Data("WhatsApp Media Retry Notification".utf8))
        var receipt = ProtoMessage()
        receipt.set(1, message.id)
        let iv = WhatsAppCipher.randomBytes(12)
        let ciphertext = try WhatsAppCipher.aesGCMSeal(key: key, nonce: iv, receipt.serialized(), authenticating: Data(message.id.utf8))
        var rmr = WhatsAppNode("rmr", ["from_me": .string(message.isFromMe ? "true" : "false")])
        rmr["jid"] = .jid(chatJID)
        if chatJID.server == WhatsAppJID.Server.group, let sender = WhatsAppJID(string: message.sender) {
            rmr["participant"] = .jid(sender)
        }
        var node = WhatsAppNode("receipt", ["id": .string(message.id), "type": "server-error"], children: [
            WhatsAppNode("encrypt", children: [WhatsAppNode("enc_p", bytes: ciphertext), WhatsAppNode("enc_iv", bytes: iv)]),
            rmr,
        ])
        node["to"] = .jid(own)
        let reply: WhatsAppNode = try await withCheckedThrowingContinuation { continuation in
            mediaRetryWaiters[message.id] = continuation
            Task {
                do {
                    try await send(node)
                } catch {
                    mediaRetryWaiters.removeValue(forKey: message.id)?.resume(throwing: error)
                    return
                }
                try? await Task.sleep(for: .seconds(30))
                mediaRetryWaiters.removeValue(forKey: message.id)?.resume(throwing: WhatsAppError.timeout)
            }
        }
        if let error = reply.child("error") {
            throw error.attr("code") == "2" ? WhatsAppError.mediaUnavailable : WhatsAppError.download
        }
        guard let encrypt = reply.child("encrypt"), let sealed = encrypt.child("enc_p")?.bytes, let nonce = encrypt.child("enc_iv")?.bytes else { throw WhatsAppError.download }
        let notification = try ProtoMessage(WhatsAppCipher.aesGCMOpen(key: key, nonce: nonce, sealed, authenticating: Data(message.id.utf8)))
        // `MediaRetryNotification`: stanzaID 1, directPath 2, result 3 (1 is SUCCESS).
        guard notification.uint64(3) == 1, let directPath = notification.string(2), !directPath.isEmpty else { throw WhatsAppError.mediaUnavailable }
        return directPath
    }

    // MARK: App state (whatsmeow appstate/)

    private func syncAppState() async {
        guard !syncingAppState else { return }
        syncingAppState = true
        defer { syncingAppState = false }
        var failed = false
        for name in Self.collections {
            do {
                try await syncCollection(name)
            } catch {
                failed = true
                logger.info("WhatsApp app state \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !failed {
            store.update { directory in
                var sync = directory.sync ?? WhatsAppSyncState()
                sync.appStateSyncedAt = Date()
                directory.sync = sync
            }
        }
        saveKeys()
        pending.reloadList = true
        flush()
    }

    private func syncCollection(_ name: String) async throws {
        var state = keys.collections[name] ?? .init(version: 0, hash: Data(count: 128), macs: [:])
        var wantSnapshot = state.version == 0
        while true {
            var collection = WhatsAppNode("collection", ["name": .string(name), "return_snapshot": .string(wantSnapshot ? "true" : "false")])
            if !wantSnapshot {
                collection["version"] = .string(String(state.version))
            }
            let response = try await iq("w:sync:app:state", "set", [WhatsAppNode("sync", children: [collection])])
            guard let result = response.child("sync", "collection") else { throw WhatsAppError.unsupported }
            if let snapshotData = result.child("snapshot")?.bytes, !snapshotData.isEmpty {
                let reference = try WhatsAppProto.ExternalBlobReference(data: snapshotData)
                let snapshot = try await WhatsAppProto.SyncdSnapshot(data: download(reference))
                try applySnapshot(snapshot, name: name, state: &state)
            }
            for patchNode in result.child("patches")?.children ?? [] {
                var patch = try WhatsAppProto.SyncdPatch(data: patchNode.bytes)
                if let external = patch.externalMutations {
                    patch.mutations = try await WhatsAppProto.SyncdMutations(data: download(external)).mutations
                }
                try applyPatch(patch, name: name, state: &state)
            }
            wantSnapshot = false
            if result.attr("has_more_patches") != "true" { break }
        }
        keys.collections[name] = state
    }

    private func download(_ reference: WhatsAppProto.ExternalBlobReference) async throws -> Data {
        try await download(directPath: reference.directPath, encSHA256: reference.fileEncSHA256, sha256: reference.fileSHA256, mediaKey: reference.mediaKey, info: "WhatsApp App State Keys", mmsType: "md-app-state")
    }

    private struct MutationKeys {
        let index, value, valueMAC, snapshotMAC, patchMAC: Data
    }

    private func mutationKeys(_ keyId: Data) throws -> MutationKeys {
        guard let key = keys.appStateKeys[keyId.hexString] else { throw WhatsAppError.unsupported }
        let expanded = WhatsAppCipher.hkdf(key.data, length: 160, info: Data("WhatsApp Mutation Keys".utf8))
        func part(_ index: Int) -> Data {
            Data(expanded[expanded.startIndex + index * 32 ..< expanded.startIndex + (index + 1) * 32])
        }
        return MutationKeys(index: part(0), value: part(1), valueMAC: part(2), snapshotMAC: part(3), patchMAC: part(4))
    }

    private static func ltHash(_ hash: inout Data, _ macs: [Data], subtract: Bool) {
        var bytes = [UInt8](hash)
        for mac in macs {
            let expanded = [UInt8](WhatsAppCipher.hkdf(mac, length: 128, info: Data("WhatsApp Patch Integrity".utf8)))
            for index in stride(from: 0, to: 128, by: 2) {
                let x = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                let y = UInt16(expanded[index]) | UInt16(expanded[index + 1]) << 8
                let result = subtract ? x &- y : x &+ y
                bytes[index] = UInt8(result & 0xFF)
                bytes[index + 1] = UInt8(result >> 8)
            }
        }
        hash = Data(bytes)
    }

    private static func snapshotMAC(_ hash: Data, version: UInt64, name: String, key: Data) -> Data {
        WhatsAppCipher.hmacSHA256(key: key, hash + withUnsafeBytes(of: version.bigEndian) { Data($0) } + Data(name.utf8))
    }

    private func decodeMutation(operation: WhatsAppProto.SyncdMutation.Operation, record: WhatsAppProto.SyncdRecord) throws -> (index: [String], value: WhatsAppProto.SyncActionValue?, indexMAC: Data, valueMAC: Data) {
        let keys = try mutationKeys(record.keyID)
        let blob = record.value
        guard blob.count > 48 else { throw WhatsAppError.unsupported }
        let content = blob.prefix(blob.count - 32)
        let valueMAC = Data(blob.suffix(32))
        let operationByte = Data([UInt8(operation.rawValue) + 1])
        let length = withUnsafeBytes(of: UInt64(record.keyID.count + 1).bigEndian) { Data($0) }
        guard WhatsAppCipher.hmacSHA512(key: keys.valueMAC, operationByte + record.keyID + content + length).prefix(32) == valueMAC else {
            throw WhatsAppError.unsupported
        }
        let plaintext = try WhatsAppCipher.aesCBCDecrypt(key: keys.value, iv: Data(content.prefix(16)), Data(content.dropFirst(16)))
        let action = try WhatsAppProto.SyncActionData(data: plaintext)
        guard WhatsAppCipher.hmacSHA256(key: keys.index, action.index) == record.index else { throw WhatsAppError.unsupported }
        let index = (try? JSONSerialization.jsonObject(with: action.index) as? [String]) ?? []
        return (index, action.value, record.index, valueMAC)
    }

    private func applySnapshot(_ snapshot: WhatsAppProto.SyncdSnapshot, name: String, state: inout WhatsAppKeyState.Collection) throws {
        state = .init(version: snapshot.version, hash: Data(count: 128), macs: [:])
        Self.ltHash(&state.hash, snapshot.records.map { Data($0.value.suffix(32)) }, subtract: false)
        let keys = try mutationKeys(snapshot.keyID)
        guard Self.snapshotMAC(state.hash, version: state.version, name: name, key: keys.snapshotMAC) == snapshot.mac else { throw WhatsAppError.unsupported }
        for record in snapshot.records {
            let mutation = try decodeMutation(operation: .set, record: record)
            state.macs[mutation.indexMAC.base64EncodedString()] = mutation.valueMAC
            applyAction(index: mutation.index, value: mutation.value, removed: false)
        }
    }

    private func applyPatch(_ patch: WhatsAppProto.SyncdPatch, name: String, state: inout WhatsAppKeyState.Collection) throws {
        var added: [Data] = []
        var removed: [Data] = []
        for (position, mutation) in patch.mutations.enumerated() {
            if mutation.operation == .set {
                added.append(Data(mutation.record.value.suffix(32)))
            }
            let indexMAC = mutation.record.index
            if let earlier = patch.mutations[..<position].last(where: { $0.record.index == indexMAC }) {
                if earlier.operation == .set { removed.append(Data(earlier.record.value.suffix(32))) }
            } else if let previous = state.macs[indexMAC.base64EncodedString()] {
                removed.append(previous)
            }
        }
        var hash = state.hash
        Self.ltHash(&hash, removed, subtract: true)
        Self.ltHash(&hash, added, subtract: false)
        let keys = try mutationKeys(patch.keyID)
        guard Self.snapshotMAC(hash, version: patch.version, name: name, key: keys.snapshotMAC) == patch.snapshotMAC else { throw WhatsAppError.unsupported }
        var patchData = patch.snapshotMAC
        for mutation in patch.mutations {
            patchData += mutation.record.value.suffix(32)
        }
        patchData += withUnsafeBytes(of: patch.version.bigEndian) { Data($0) } + Data(name.utf8)
        guard WhatsAppCipher.hmacSHA256(key: keys.patchMAC, patchData) == patch.patchMAC else { throw WhatsAppError.unsupported }
        state.hash = hash
        state.version = patch.version
        for mutation in patch.mutations {
            let decoded = try decodeMutation(operation: mutation.operation, record: mutation.record)
            if mutation.operation == .set {
                state.macs[decoded.indexMAC.base64EncodedString()] = decoded.valueMAC
            } else {
                state.macs[decoded.indexMAC.base64EncodedString()] = nil
            }
            applyAction(index: decoded.index, value: decoded.value, removed: mutation.operation == .remove)
        }
    }

    /// Folds an app state mutation into the store: contact names, mute, archive, pin, read.
    private func applyAction(index: [String], value: WhatsAppProto.SyncActionValue?, removed: Bool) {
        guard index.count > 1, let value else { return }
        let target = index[1]
        switch index[0] {
        case "contact":
            let name = removed ? nil : (value.contactAction?.fullName ?? value.contactAction?.firstName)
            store.update { directory in
                directory.contactNames[target] = name
                // Contacts carry both addresses, so a chat that arrives by LID still finds the contact's name.
                if let lid = value.contactAction?.lidJID.flatMap(WhatsAppJID.init(string:)) {
                    directory.contactNames[lid.nonAD.description] = name
                    if let phone = WhatsAppJID(string: target), phone.server == WhatsAppJID.Server.user {
                        directory.lidByPhoneNumber[phone.user] = lid.user
                    }
                }
            }
        case "mute":
            let end = value.muteAction.flatMap { $0.muted ? ($0.muteEndTimestamp ?? -1) : nil }
            store.updateChat(target) { $0.muteEnd = removed ? nil : end }
        case "archive":
            store.updateChat(target) { $0.isArchived = !removed && value.archived == true }
        case "pin_v1":
            store.updateChat(target) { $0.isPinned = !removed && value.pinned == true }
        case "markChatAsRead":
            if value.read == true {
                store.updateChat(target) {
                    $0.unreadCount = 0
                    $0.markedUnread = false
                    $0.readUpTo = max($0.readUpTo ?? .distantPast, value.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? Date())
                }
            } else if value.read == false {
                store.updateChat(target) { $0.markedUnread = true }
            }
        default:
            break
        }
    }

    // MARK: Groups

    private func fetchGroups() async throws {
        let response = try await iq("w:g2", "get", to: WhatsAppJID(user: "", server: WhatsAppJID.Server.group), [
            WhatsAppNode("participating", children: [WhatsAppNode("participants"), WhatsAppNode("description")]),
        ])
        var subjects: [String: String] = [:]
        var members: [String: [WhatsAppStore.GroupMember]] = [:]
        var descriptions: [String: String] = [:]
        var addressing: [String: String] = [:]
        var announcement: Set<String> = []
        for group in response.child("groups")?.children ?? [] where group.tag == "group" {
            guard let id = group.attr("id") else { continue }
            let groupJID = "\(id)@\(WhatsAppJID.Server.group)"
            subjects[groupJID] = group.attr("subject") ?? ""
            addressing[groupJID] = group.attr("addressing_mode")
            // A group created or joined recently that history didn't include (it has no messages yet) is listed from
            // its creation time, as WhatsApp lists a new group; older empty groups aren't.
            if let created = group.attr("creation").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
               created > Date().addingTimeInterval(-14 * 24 * 3600), store.chat(groupJID)?.lastTimestamp == nil
            {
                store.updateChat(groupJID) { $0.lastTimestamp = created }
            }
            if group.child("announcement") != nil {
                announcement.insert(groupJID)
            }
            if let body = group.child("description", "body"), case let .string(text) = body.content {
                descriptions[groupJID] = text
            } else if let body = group.child("description", "body"), !body.bytes.isEmpty {
                descriptions[groupJID] = String(decoding: body.bytes, as: UTF8.self)
            }
            for participant in group.children where participant.tag == "participant" {
                guard let jid = participant.jid("jid") else { continue }
                members[groupJID, default: []].append(.init(jid: jid.nonAD.description, role: participant.attr("type")))
                if jid.server == WhatsAppJID.Server.lid {
                    storeLID(phoneNumber: participant.jid("phone_number"), lid: jid)
                } else {
                    storeLID(phoneNumber: jid, lid: participant.jid("lid"))
                }
            }
        }
        store.update {
            $0.groupSubjects = subjects
            $0.groupMembers = members
            $0.groupDescriptions = descriptions
            $0.groupAddressing = addressing
            $0.announcementGroups = announcement
        }
        pending.reloadList = true
        flush()
    }

    // MARK: Profile pictures (whatsmeow GetProfilePictureInfo)

    /// Queues lookups for pictures that aren't known or are about to expire; they run one at a time, spaced out,
    /// while connected.
    func requestAvatars(for jids: [String], in chat: String? = nil) {
        let wanted = jids.filter { store.needsAvatar($0) && !avatarQueue.contains($0) }
        if let chat {
            for jid in wanted {
                avatarRequesters[jid] = chat
            }
        }
        guard !wanted.isEmpty else { return }
        avatarQueue.append(contentsOf: wanted)
        guard avatarTask == nil else { return }
        avatarTask = Task { await drainAvatars() }
    }

    private func drainAvatars() async {
        let count = avatarQueue.count
        logger.info("WhatsApp looking up \(count) pictures")
        defer { avatarTask = nil }
        while socket != nil, !avatarQueue.isEmpty {
            let jid = avatarQueue.removeFirst()
            guard store.needsAvatar(jid), let target = WhatsAppJID(string: jid) else { continue }
            do {
                let url = try await fetchAvatar(target)
                store.update { $0.avatars[jid] = WhatsAppStore.Avatar(url: url, checkedAt: Date(), expires: url.flatMap(Self.expiry) ?? Date().addingTimeInterval(7 * 24 * 3600)) }
                pending.chats.insert(avatarRequesters.removeValue(forKey: jid) ?? jid)
                flush()
            } catch WhatsAppError.notConnected {
                avatarQueue.insert(jid, at: 0)
                return
            } catch {
                logger.info("WhatsApp picture lookup failed: \(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: Self.avatarSpacing)
        }
    }

    /// The preview picture's URL; `nil` when there is none to show (404) or it's hidden from the user (401).
    private func fetchAvatar(_ jid: WhatsAppJID) async throws -> URL? {
        do {
            let picture = privacyTokenNode(for: jid).map { WhatsAppNode("picture", ["query": "url", "type": "preview"], children: [$0]) }
                ?? WhatsAppNode("picture", ["query": "url", "type": "preview"])
            let response = try await iq("w:profile:picture", "get", target: jid.nonAD, [picture])
            guard let picture = response.child("picture"), picture.attr("status") == nil else { return nil }
            return picture.attr("url").flatMap(URL.init(string:))
        } catch let WhatsAppError.iq(code, _) where code == "404" || code == "401" {
            return nil
        }
    }

    /// The `oe` parameter: the signed URL's expiry as hex Unix seconds.
    private static func expiry(of url: URL) -> Date? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "oe" }?.value
            .flatMap { UInt64($0, radix: 16) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    // MARK: Sending (whatsmeow send.go)

    private func messageId() -> String {
        let own = device?.jid?.user ?? ""
        let data = withUnsafeBytes(of: UInt64(Date().timeIntervalSince1970).bigEndian) { Data($0) } + Data("\(own)@c.us".utf8) + WhatsAppCipher.randomBytes(16)
        return "3EB0" + WhatsAppCipher.sha256(data).prefix(9).hexString.uppercased()
    }

    private func devices(of users: [WhatsAppJID]) async throws -> [WhatsAppJID] {
        let list = users.map { user -> WhatsAppNode in
            var node = WhatsAppNode("user")
            node["jid"] = .jid(user.nonAD)
            return node
        }
        let usync = WhatsAppNode("usync", ["sid": .string(requestId()), "mode": "query", "last": "true", "index": "0", "context": "message"], children: [
            WhatsAppNode("query", children: [WhatsAppNode("devices", ["version": "2"])]),
            WhatsAppNode("list", children: list),
        ])
        let response = try await iq("usync", "get", [usync])
        var devices: [WhatsAppJID] = []
        for user in response.child("usync", "list")?.children ?? [] {
            guard let jid = user.jid("jid") else { continue }
            for device in user.child("devices", "device-list")?.children ?? [] where device.tag == "device" && device.attr("is_hosted") != "true" {
                if let id = device.attr("id").flatMap(Int.init) {
                    devices.append(WhatsAppJID(user: jid.user, server: jid.server, device: id))
                }
            }
        }
        return devices
    }

    private func bundles(for devices: [WhatsAppJID]) async throws -> [String: WhatsAppPreKeyBundle] {
        let users = devices.map { device -> WhatsAppNode in
            var node = WhatsAppNode("user", ["reason": "identity"])
            node["jid"] = .jid(device)
            return node
        }
        let response = try await iq("encrypt", "get", [WhatsAppNode("key", children: users)])
        var bundles: [String: WhatsAppPreKeyBundle] = [:]
        for user in response.child("list")?.children ?? [] where user.tag == "user" && user.child("error") == nil {
            guard let jid = user.jid("jid"), let bundle = Self.bundle(keys: user.child("keys") ?? user, registration: user.child("registration")) else { continue }
            bundles[jid.signalAddress] = bundle
        }
        return bundles
    }

    /// A prekey bundle from `<keys>` (identity, `<key>`, `<skey>`) and `<registration>`, as key fetches and retry
    /// receipts carry them (whatsmeow nodeToPreKeyBundle).
    static func bundle(keys: WhatsAppNode, registration: WhatsAppNode?) -> WhatsAppPreKeyBundle? {
        func id(_ node: WhatsAppNode?) -> UInt32 {
            (node?.child("id")?.bytes ?? Data()).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        guard let signed = keys.child("skey"), let identity = keys.child("identity")?.bytes, let registration = registration?.bytes else { return nil }
        let preKey = keys.child("key")
        return WhatsAppPreKeyBundle(
            registrationId: registration.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, identity: identity, signedPreKeyId: id(signed),
            signedPreKey: signed.child("value")?.bytes ?? Data(), signature: signed.child("signature")?.bytes ?? Data(),
            preKeyId: preKey.map { id($0) }, preKey: preKey?.child("value")?.bytes,
        )
    }

    // MARK: Retries (whatsmeow retry.go)

    /// Asks the sender to encrypt a message this device couldn't decrypt again: at most four times, with a fresh
    /// one-time prekey and our identity from the second time on. The first time, the phone is also asked to resend
    /// it (an unavailable-message request) after 5 s, in case the sender doesn't.
    private func sendRetryReceipt(for node: WhatsAppNode, id: String, source: Source) async {
        guard let device, let account = device.account else { return }
        var count = (retryCounts[id] ?? 0) + 1
        let encs = node.children.filter { $0.tag == "enc" }
        if count == 1, encs.count == 1, let sent = encs[0].attr("count").flatMap(Int.init) {
            count = sent + 1
        }
        retryCounts[id] = count
        guard count < 5 else {
            logger.info("WhatsApp not sending more retry receipts for a message")
            return
        }
        var children = [
            WhatsAppNode("retry", ["count": .string(String(count)), "id": .string(id), "t": .string(node.attr("t") ?? String(Int(Date().timeIntervalSince1970))), "v": "1"]),
            WhatsAppNode("registration", bytes: withUnsafeBytes(of: device.registrationId.bigEndian) { Data($0) }),
        ]
        if count > 1 {
            let preKeyId = keys.nextPreKeyId
            keys.nextPreKeyId += 1
            let pair = WhatsAppKeyPair.generate()
            keys.preKeys[String(preKeyId)] = pair
            saveKeys()
            children.append(WhatsAppNode("keys", children: [
                WhatsAppNode("type", bytes: Data([5])),
                WhatsAppNode("identity", bytes: device.identityKey.publicKey),
                WhatsAppNode("key", children: [WhatsAppNode("id", bytes: Self.uint24(preKeyId)), WhatsAppNode("value", bytes: pair.publicKey)]),
                WhatsAppNode("skey", children: [
                    WhatsAppNode("id", bytes: Self.uint24(device.signedPreKey.id)),
                    WhatsAppNode("value", bytes: device.signedPreKey.keyPair.publicKey),
                    WhatsAppNode("signature", bytes: device.signedPreKey.signature),
                ]),
                WhatsAppNode("device-identity", bytes: account),
            ]))
        }
        var receipt = WhatsAppNode("receipt", ["id": .string(id), "type": "retry"], children: children)
        receipt["to"] = node["from"]
        receipt["participant"] = node["participant"]
        receipt["recipient"] = node["recipient"]
        if node.attr("type") == "peer_msg", source.isFromMe {
            receipt["category"] = "peer"
        }
        try? await send(receipt)
        if count == 1 {
            Task {
                try? await Task.sleep(for: .seconds(5))
                await requestUnavailableMessage(id: id, source: source)
            }
        }
    }

    /// Asks the phone for a message this device couldn't decrypt (whatsmeow BuildUnavailableMessageRequest); the
    /// phone answers with the message in a peer response, stored like history.
    private func requestUnavailableMessage(id: String, source: Source) async {
        guard store.messages(in: canonicalChat(source.chat)).first(where: { $0.id == id }) == nil else { return }
        let key = WhatsAppProto.MessageKey(remoteJID: source.chat.description, fromMe: source.isFromMe, id: id,
                                           participant: source.isGroup ? source.sender.nonAD.description : nil)
        var request = ProtoMessage()
        request.set(1, key.proto)
        var operation = ProtoMessage()
        operation.set(1, UInt64(4)) // PLACEHOLDER_MESSAGE_RESEND
        operation.set(5, request)
        var protocolMessage = ProtoMessage()
        protocolMessage.set(2, UInt64(16)) // PEER_DATA_OPERATION_REQUEST_MESSAGE
        protocolMessage.set(16, operation)
        var wrapper = ProtoMessage()
        wrapper.set(WhatsAppProto.Message.Field.protocolMessage, protocolMessage)
        try? await sendPeer(wrapper, historyRequest: false)
    }

    /// Another device couldn't decrypt one of our messages: encrypt it again for that device (with the keys the
    /// receipt carries, or a new session when there's none), at most ten times per device and message.
    private func handleRetryReceipt(_ node: WhatsAppNode) async {
        guard let retry = node.child("retry"), let id = retry.attr("id"), let requester = node.jid("participant") ?? node.jid("from"),
              let recent = recentSent[id], let own = device?.jid, let ownLID = device?.lid, let account = device?.account
        else { return }
        let counterKey = "\(requester.description)/\(id)"
        incomingRetryCounts[counterKey, default: 0] += 1
        guard incomingRetryCounts[counterKey]! < 10 else { return }
        let isOwnDevice = requester.user == own.user || requester.user == ownLID.user
        var message = isOwnDevice ? WhatsAppProto.Message.deviceSent(recent.message, destinationJID: recent.recipient) : recent.message
        if recent.recipient.hasSuffix("@\(WhatsAppJID.Server.group)") {
            // A group message goes again as a 1:1 message, with the sender key alongside (whatsmeow handleRetryReceipt).
            var store = signal
            var distribution = ProtoMessage()
            distribution.set(1, recent.recipient)
            distribution.set(2, store.senderKeyDistribution(group: recent.recipient, ownAddress: WhatsAppJID(user: ownLID.user, server: WhatsAppJID.Server.lid, device: ownLID.device).signalAddress))
            signal = store
            var proto = recent.message.proto
            proto.set(WhatsAppProto.Message.Field.senderKeyDistribution, distribution)
            message = WhatsAppProto.Message(proto: proto)
        }
        let address = requester.server == WhatsAppJID.Server.user ? (lid(for: requester) ?? requester) : requester
        var store = signal
        do {
            if let keys = node.child("keys"), let bundle = Self.bundle(keys: keys, registration: node.child("registration")) {
                try store.buildSession(address: address.signalAddress, bundle: bundle)
            } else if !store.hasSession(address: address.signalAddress) {
                for (bundleAddress, bundle) in try await bundles(for: [address]) {
                    try? store.buildSession(address: bundleAddress, bundle: bundle)
                }
            }
            let encrypted = try store.encrypt(address: address.signalAddress, WhatsAppMessagePadding.pad(message.proto.serialized()))
            signal = store
            saveKeys()
            var enc = WhatsAppNode("enc", ["v": "2", "type": .string(encrypted.type.rawValue)], bytes: encrypted.data)
            enc["count"] = retry["count"]
            var children = [enc]
            if encrypted.type == .pkmsg {
                children.append(WhatsAppNode("device-identity", bytes: account))
            }
            var resend = WhatsAppNode("message", ["id": .string(id), "type": "text", "device_fanout": "false"], children: children)
            resend["to"] = node["from"]
            resend["t"] = retry["t"]
            resend["participant"] = node["participant"]
            resend["recipient"] = node["recipient"]
            try await send(resend)
        } catch {
            logger.info("WhatsApp retry resend failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends text to a one-to-one chat, addressed by LID: the recipient's devices get the message, the user's other
    /// devices a `DeviceSentMessage`. Group sending isn't validated in the probe yet.
    /// Sends text, as a reply when `replyTo` names a stored message (quoting it, as WhatsApp's apps do).
    public func sendText(_ text: String, to chat: String, replyTo: String? = nil) async throws -> WhatsAppMessage {
        let quoted = replyTo.flatMap { id in store.messages(in: chat).first { $0.id == id } }
        let own = device?.jid?.nonAD.description ?? ""
        let context = quoted.map { quoted in
            WhatsAppProto.ContextInfo(stanzaID: quoted.id, participant: quoted.isFromMe ? own : quoted.sender, quotedMessage: .text(quoted.text ?? ""))
        }
        let message = WhatsAppProto.Message.text(text, contextInfo: context)
        let (id, timestamp) = try await send(message, to: chat)
        guard let ownJID = device?.jid else { throw WhatsAppError.notLinked }
        let sent = WhatsAppMessage(id: id, sender: ownJID.nonAD.description, isFromMe: true, timestamp: timestamp, text: text, label: nil,
                                   quotedId: quoted?.id, quotedSender: context?.participant)
        store.upsert([sent], in: chat)
        store.updateChat(chat) {
            $0.unreadCount = 0
            $0.readUpTo = timestamp
        }
        pending.chats.insert(chat)
        flush()
        return sent
    }

    /// Uploads a file and sends it as a photo, video, voice message or document, with a caption and as a reply
    /// when given (validated with the probe's `send-media`, 2026-11-22). The file goes into the media cache, so the
    /// sent bubble shows it without downloading it again.
    public func sendMedia(_ media: WhatsAppOutgoingMedia, caption: String?, to chat: String, replyTo: String? = nil, accountId: String) async throws -> WhatsAppMessage {
        let uploaded = try await upload(media.data, kind: media.kind)
        let kind: WhatsAppProto.MediaMessage.Kind = switch media.kind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .document: .document
        case .sticker: .sticker
        }
        // url, mimetype, caption, fileSHA256, fileLength, height, width, mediaKey, fileEncSHA256, directPath,
        // jpegThumbnail, seconds, ptt, fileName.
        let f = kind.fields
        var proto = ProtoMessage()
        f[0].map { proto.set($0, uploaded.url) }
        f[1].map { proto.set($0, media.mimetype) }
        if let caption, !caption.isEmpty { f[2].map { proto.set($0, caption) } }
        f[3].map { proto.set($0, WhatsAppCipher.sha256(media.data)) }
        f[4].map { proto.set($0, UInt64(media.data.count)) }
        if let height = media.height { f[5].map { proto.set($0, height) } }
        if let width = media.width { f[6].map { proto.set($0, width) } }
        f[7].map { proto.set($0, uploaded.mediaKey) }
        f[8].map { proto.set($0, uploaded.fileEncSHA256) }
        f[9].map { proto.set($0, uploaded.directPath) }
        if let thumbnail = media.thumbnail { f[10].map { proto.set($0, thumbnail) } }
        if let seconds = media.seconds { f[11].map { proto.set($0, seconds) } }
        if media.isVoice { f[12].map { proto.set($0, true) } }
        if let fileName = media.fileName { f[13].map { proto.set($0, fileName) } }
        // mediaKeyTimestamp.
        let timestampField = switch media.kind {
        case .image: 12
        case .video: 14
        case .audio, .sticker: 10
        case .document: 11
        }
        proto.set(timestampField, Int64(Date().timeIntervalSince1970))
        if let waveform = media.waveform, media.kind == .audio { proto.set(19, waveform) }
        let quoted = replyTo.flatMap { id in store.messages(in: chat).first { $0.id == id } }
        let own = device?.jid?.nonAD.description ?? ""
        let context = quoted.map { WhatsAppProto.ContextInfo(stanzaID: $0.id, participant: $0.isFromMe ? own : $0.sender, quotedMessage: .text($0.text ?? "")) }
        if let context { proto.set(17, context.proto) }
        var wrapper = ProtoMessage()
        wrapper.set(kind.field, proto)
        let message = WhatsAppProto.Message(proto: wrapper)
        let (id, timestamp) = try await send(message, to: chat)
        let stored = WhatsAppMessage(id: id, sender: own, isFromMe: true, timestamp: timestamp, text: caption?.isEmpty == false ? caption : nil,
                                     label: message.media.flatMap { _ in Self.label(of: message) }, quotedId: quoted?.id, media: message.media.map(Self.media),
                                     quotedSender: context?.participant)
        if let fileExtension = stored.media?.fileExtension {
            let file = WhatsAppMediaCache.file(for: .init(accountId: accountId, chat: chat, messageId: id, fileExtension: fileExtension, isThumbnail: false))
            try? FileManager.default.createDirectory(at: WhatsAppMediaCache.directory, withIntermediateDirectories: true)
            try? media.data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        store.upsert([stored], in: chat)
        store.updateChat(chat) {
            $0.unreadCount = 0
            $0.readUpTo = timestamp
        }
        pending.chats.insert(chat)
        flush()
        return stored
    }

    /// Encrypts and uploads a file (whatsmeow Upload): AES-CBC under keys from a fresh media key and a 10-byte
    /// HMAC, POSTed to the first media host with `media_conn`'s auth token.
    private func upload(_ data: Data, kind: WhatsAppMedia.Kind) async throws -> (url: String, directPath: String, mediaKey: Data, fileEncSHA256: Data) {
        let mediaKey = WhatsAppCipher.randomBytes(32)
        let expanded = WhatsAppCipher.hkdf(mediaKey, length: 112, info: Data(kind.keyInfo.utf8))
        let iv = expanded.prefix(16)
        let cipherKey = expanded[expanded.startIndex + 16 ..< expanded.startIndex + 48]
        let macKey = expanded[expanded.startIndex + 48 ..< expanded.startIndex + 80]
        let ciphertext = try WhatsAppCipher.aesCBCEncrypt(key: Data(cipherKey), iv: Data(iv), data)
        let body = ciphertext + WhatsAppCipher.hmacSHA256(key: Data(macKey), Data(iv) + ciphertext).prefix(10)
        let encSHA256 = WhatsAppCipher.sha256(body)
        let connection = try await iq("w:m", "set", [WhatsAppNode("media_conn")]).child("media_conn")
        guard let auth = connection?.attr("auth"), let host = connection?.children.first(where: { $0.tag == "host" })?.attr("hostname") else { throw WhatsAppError.upload }
        let token = encSHA256.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/mms/\(kind.mmsType)/\(token)"
        components.queryItems = [URLQueryItem(name: "auth", value: auth), URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw WhatsAppError.upload }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(WhatsAppSocket.origin, forHTTPHeaderField: "Origin")
        request.setValue(WhatsAppSocket.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let fileURL = json["url"] as? String, let directPath = json["direct_path"] as? String
        else { throw WhatsAppError.upload }
        return (fileURL, directPath, mediaKey, encSHA256)
    }

    /// Reacts to a message with an emoji, or takes the user's reaction back with an empty one.
    public func sendReaction(_ emoji: String, to messageId: String, in chat: String) async throws {
        guard let target = store.messages(in: chat).first(where: { $0.id == messageId }), let own = device?.jid?.nonAD.description else { throw WhatsAppError.unsupported }
        let isGroup = chat.hasSuffix("@\(WhatsAppJID.Server.group)")
        let key = WhatsAppProto.MessageKey(remoteJID: chat, fromMe: target.isFromMe, id: target.id, participant: isGroup && !target.isFromMe ? target.sender : nil)
        _ = try await send(.reaction(to: key, text: emoji, senderTimestampMS: Int64(Date().timeIntervalSince1970 * 1000)), to: chat)
        _ = store.modifyMessage(messageId, in: chat) { $0.reactions[own] = emoji.isEmpty ? nil : emoji }
        pending.chats.insert(chat)
        flush()
    }

    /// One-to-one send in LID addressing: the recipient's devices get the message and the user's other devices a
    /// `DeviceSentMessage`, with the recipient's privacy token. Returns the id and the server's time.
    private func send(_ message: WhatsAppProto.Message, to chat: String) async throws -> (String, Date) {
        guard let device, device.jid != nil, let ownLID = device.lid, let account = device.account else { throw WhatsAppError.notLinked }
        guard var recipient = WhatsAppJID(string: chat) else { throw WhatsAppError.unsupported }
        let isGroup = recipient.server == WhatsAppJID.Server.group
        var phoneNumber: WhatsAppJID?
        if recipient.server == WhatsAppJID.Server.user {
            guard let lid = lid(for: recipient) else { throw WhatsAppError.noLID }
            phoneNumber = recipient
            recipient = lid.nonAD
        }
        let plaintext = message.proto.serialized()
        let ownUser = WhatsAppJID(user: ownLID.user, server: WhatsAppJID.Server.lid)
        let ownAddress = WhatsAppJID(user: ownLID.user, server: WhatsAppJID.Server.lid, device: ownLID.device).signalAddress
        // A group gets the message once, under the user's sender key (`skmsg`); every participant device gets the
        // sender key itself in a 1:1 message (whatsmeow sendGroup). A 1:1 chat's recipient devices get the
        // message, the user's other devices a `DeviceSentMessage`.
        let users: [WhatsAppJID]
        let payloadFor: (WhatsAppJID) -> Data
        var groupCiphertext: Data?
        var store = signal
        if isGroup {
            users = try groupParticipants(chat).filter { $0.user != ownLID.user && $0.user != device.jid?.user } + [ownUser]
            var distribution = ProtoMessage()
            distribution.set(1, chat)
            distribution.set(2, store.senderKeyDistribution(group: chat, ownAddress: ownAddress))
            var wrapper = ProtoMessage()
            wrapper.set(WhatsAppProto.Message.Field.senderKeyDistribution, distribution)
            let distributionPlaintext = wrapper.serialized()
            payloadFor = { _ in distributionPlaintext }
            groupCiphertext = try store.encryptGroupMessage(group: chat, ownAddress: ownAddress, WhatsAppMessagePadding.pad(plaintext))
        } else {
            let deviceSent = WhatsAppProto.Message.deviceSent(message, destinationJID: recipient.description).proto.serialized()
            users = recipient.user == ownLID.user ? [recipient] : [recipient, ownUser]
            payloadFor = { $0.user == ownLID.user ? deviceSent : plaintext }
        }
        let targets = try await devices(of: users).filter { !($0.user == ownLID.user && $0.device == ownLID.device) }
        let missing = targets.filter { !store.hasSession(address: $0.signalAddress) }
        if !missing.isEmpty {
            for (address, bundle) in try await bundles(for: missing) {
                try? store.buildSession(address: address, bundle: bundle)
            }
        }
        let (type, mediaType) = Self.messageType(message)
        var participants: [WhatsAppNode] = []
        var includesIdentity = false
        for target in targets where store.hasSession(address: target.signalAddress) {
            let encrypted = try store.encrypt(address: target.signalAddress, WhatsAppMessagePadding.pad(payloadFor(target)))
            includesIdentity = includesIdentity || encrypted.type == .pkmsg
            var enc = WhatsAppNode("enc", ["v": "2", "type": .string(encrypted.type.rawValue)], bytes: encrypted.data)
            if !isGroup, let mediaType {
                enc["mediatype"] = .string(mediaType)
            }
            var to = WhatsAppNode("to", children: [enc])
            to["jid"] = .jid(target)
            participants.append(to)
        }
        signal = store
        saveKeys()
        let id = messageId()
        var children = [WhatsAppNode("participants", children: participants)]
        if let groupCiphertext {
            var enc = WhatsAppNode("enc", ["v": "2", "type": "skmsg"], bytes: groupCiphertext)
            if let mediaType {
                enc["mediatype"] = .string(mediaType)
            }
            children.append(enc)
        }
        if includesIdentity {
            children.append(WhatsAppNode("device-identity", bytes: account))
        }
        if !isGroup, let token = privacyTokenNode(for: recipient) {
            children.append(token)
        }
        var node = WhatsAppNode("message", ["id": .string(id), "type": .string(type)], children: children)
        node["to"] = .jid(recipient)
        if let phoneNumber {
            node["peer_recipient_pn"] = .jid(phoneNumber)
        }
        if isGroup {
            // whatsmeow participantListHashV2: "2:" and the base64 of the first 6 bytes of SHA-256 over the sorted
            // device JIDs.
            let joined = (targets + [WhatsAppJID(user: ownLID.user, server: WhatsAppJID.Server.lid, device: ownLID.device)]).map(\.description).sorted().joined()
            node["phash"] = .string("2:" + WhatsAppCipher.sha256(Data(joined.utf8)).prefix(6).base64EncodedString().replacingOccurrences(of: "=", with: ""))
            if store_isLIDGroup(chat) {
                node["addressing_mode"] = "lid"
            }
        }
        let ack = try await request(node, id: id)
        if let error = ack.attr("error") {
            throw WhatsAppError.sendFailed(error)
        }
        if !isGroup {
            Task { await issuePrivacyTokenIfNeeded(to: recipient) }
        }
        let timestamp = ack.attr("t").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
        recentSent[id] = (recipient.description, message)
        recentSentOrder.append(id)
        if recentSentOrder.count > 256 {
            recentSent[recentSentOrder.removeFirst()] = nil
        }
        return (id, timestamp)
    }

    /// The node's `type` and the `enc`'s `mediatype` (whatsmeow getTypeFromMessage, getMediaTypeFromMessage).
    static func messageType(_ message: WhatsAppProto.Message) -> (type: String, mediaType: String?) {
        let content = message.unwrapped
        if content.reaction != nil { return ("reaction", nil) }
        if let media = content.media {
            let mediaType = switch media.kind {
            case .image: "image"
            case .sticker: "sticker"
            case .document: "document"
            case .audio: media.ptt == true ? "ptt" : "audio"
            case .video: media.isAnimated == true ? "gif" : "video"
            }
            return ("media", mediaType)
        }
        return ("text", nil)
    }

    /// A group's participants as the group addresses them (LIDs in LID-addressed groups), from `<participating>`.
    private func groupParticipants(_ chat: String) throws -> [WhatsAppJID] {
        let members = store.directory.groupMembers?[chat] ?? []
        guard !members.isEmpty else { throw WhatsAppError.unsupported }
        return members.compactMap { WhatsAppJID(string: $0.jid) }
    }

    private func store_isLIDGroup(_ chat: String) -> Bool {
        store.directory.groupAddressing?[chat] == "lid"
    }

    /// Whether the user can send to the group: not when only admins can and they aren't one.
    public func canSend(to chat: String) -> Bool {
        guard chat.hasSuffix("@\(WhatsAppJID.Server.group)") else { return true }
        guard let members = store.directory.groupMembers?[chat], !members.isEmpty else { return false }
        guard store.directory.announcementGroups?.contains(chat) == true else { return true }
        let own: Set = [device?.jid?.user, device?.lid?.user].compactMap(\.self).reduce(into: Set<String>()) { $0.insert($1) }
        return members.contains { own.contains(String($0.jid.prefix { $0 != "@" })) && $0.role != nil }
    }

    // MARK: Presence and typing (whatsmeow presence.go; validated with the probe's `typing`, 2026-11-22)

    /// Online while any WhatsApp chat is open in the foreground, as WhatsApp Web is while it has focus: presence
    /// changes only when the first chat opens and the last one closes.
    public func setAvailable(_ available: Bool) async {
        openChats = max(openChats + (available ? 1 : -1), 0)
        guard available ? openChats == 1 : openChats == 0 else { return }
        var node = WhatsAppNode("presence", ["type": .string(available ? "available" : "unavailable")])
        if let name = device?.pushName, !name.isEmpty {
            node["name"] = .string(name)
        }
        try? await send(node)
    }

    /// Asks for a person's typing and online state while their chat is open, with their privacy token.
    public func subscribePresence(_ chat: String) async {
        guard let jid = WhatsAppJID(string: chat), jid.server != WhatsAppJID.Server.group else { return }
        let target = jid.server == WhatsAppJID.Server.user ? (lid(for: jid)?.nonAD ?? jid) : jid
        var node = privacyTokenNode(for: target).map { WhatsAppNode("presence", ["type": "subscribe"], children: [$0]) } ?? WhatsAppNode("presence", ["type": "subscribe"])
        node["to"] = .jid(target)
        try? await send(node)
    }

    /// `<chatstate to><composing/>` while the user types, `<paused/>` when they stop.
    public func sendTyping(_ typing: Bool, in chat: String) async {
        guard let jid = WhatsAppJID(string: chat) else { return }
        var node = WhatsAppNode("chatstate", children: [WhatsAppNode(typing ? "composing" : "paused")])
        node["to"] = .jid(jid)
        try? await send(node)
    }

    /// Read receipts for others' messages up to `time`, one per sender (whatsmeow `MarkRead`); `read-self` when
    /// the user turned read receipts off in WhatsApp.
    public func markRead(_ messages: [WhatsAppMessage], in chat: String, upTo time: Date) async throws {
        store.updateChat(chat) {
            $0.readUpTo = max($0.readUpTo ?? .distantPast, time)
            $0.unreadCount = 0
            $0.markedUnread = false
        }
        pending.chats.insert(chat)
        flush()
        guard let chatJID = WhatsAppJID(string: chat) else { return }
        let isGroup = chatJID.server == WhatsAppJID.Server.group
        for (sender, group) in Dictionary(grouping: messages, by: \.sender) {
            guard let first = group.first else { continue }
            var receipt = WhatsAppNode("receipt", ["id": .string(first.id), "type": .string(keys.readReceipts ? "read" : "read-self"), "t": .string(String(Int(Date().timeIntervalSince1970)))])
            receipt["to"] = .jid(chatJID)
            if isGroup, let participant = WhatsAppJID(string: sender) {
                receipt["participant"] = .jid(participant.nonAD)
            }
            if group.count > 1 {
                receipt.content = .nodes([WhatsAppNode("list", children: group.dropFirst().map { WhatsAppNode("item", ["id": .string($0.id)]) })])
            }
            try await send(receipt)
        }
    }

    // MARK: Reading the store

    /// A group's description and members (names, pictures as far as they're looked up, roles), admins first.
    /// Pictures of the first members shown are looked up as for any chat, one a second.
    public func groupInfo(_ chat: String) -> (description: String?, members: [ChatMemberSummary]) {
        let members = store.directory.groupMembers?[chat] ?? []
        let ownUsers: Set = [device?.jid?.user, device?.lid?.user].compactMap(\.self).reduce(into: Set<String>()) { $0.insert($1) }
        let order: (String?) -> Int = { $0 == "superadmin" ? 0 : $0 == "admin" ? 1 : 2 }
        let sorted = members.sorted { order($0.role) != order($1.role) ? order($0.role) < order($1.role) : (store.name(forUserJID: $0.jid) ?? "~") < (store.name(forUserJID: $1.jid) ?? "~") }
        requestAvatars(for: Array(sorted.prefix(30).map(\.jid)), in: chat)
        let summaries = sorted.map { member in
            let user = String(member.jid.prefix { $0 != "@" })
            let tags = member.role == "superadmin" ? ["owner"] : member.role == "admin" ? ["admin"] : []
            return ChatMemberSummary(id: member.jid, name: store.name(forUserJID: member.jid) ?? (member.jid.hasSuffix("@\(WhatsAppJID.Server.user)") ? "+\(user)" : "Unknown"),
                                     avatarURL: store.avatarURL(for: member.jid), tags: tags, isYou: ownUsers.contains(user))
        }
        return (store.directory.groupDescriptions?[chat], summaries)
    }

    /// The user's own WhatsApp name and profile picture, for the account's row in Settings. The picture's URL is
    /// signed and expires, so it's looked up again once the stored one is due.
    public func ownProfile() async -> (name: String?, avatarURL: URL?) {
        guard let jid = device?.jid?.nonAD else { return (nil, nil) }
        let key = jid.description
        let name = device?.pushName.flatMap { $0.isEmpty ? nil : $0 } ?? store.name(forUserJID: key)
        if store.needsAvatar(key), let fetched = try? await fetchAvatar(jid) {
            store.update { $0.avatars[key] = WhatsAppStore.Avatar(url: fetched, checkedAt: Date(), expires: Self.expiry(of: fetched) ?? Date().addingTimeInterval(7 * 24 * 3600)) }
        }
        return (name, store.avatarURL(for: key))
    }

    /// The user's own JID, which keys their reactions.
    public var ownUser: String? {
        device?.jid?.nonAD.description
    }

    /// A stored message, such as the anchor for an on-demand history request.
    public func message(_ id: String, in chat: String) -> WhatsAppMessage? {
        store.messages(in: chat).first { $0.id == id }
    }

    public func chatPage(_ chat: String) -> WhatsAppChatPage {
        let messages = store.messages(in: chat)
        var names: [String: String] = [:]
        for sender in Set(messages.filter { !$0.isFromMe }.map(\.sender)) {
            names[sender] = store.name(forUserJID: sender)
        }
        let stored = store.chat(chat)
        var readUpTo = stored?.readUpTo
        if readUpTo == nil, let stored {
            // From history's unread count: the newest that many messages from others are unread.
            let incoming = messages.filter { !$0.isFromMe }
            let unread = min(stored.unreadCount, incoming.count)
            readUpTo = unread == 0 ? (messages.last?.timestamp ?? .distantPast) : incoming.count > unread ? incoming[incoming.count - unread - 1].timestamp : .distantPast
        }
        let senders = Set(messages.filter { !$0.isFromMe }.map(\.sender))
        requestAvatars(for: [chat] + senders.sorted(), in: chat)
        let avatars = senders.reduce(into: [String: URL]()) { result, sender in
            result[sender] = store.avatarURL(for: sender)
        }
        return WhatsAppChatPage(
            title: stored.map(store.title(for:)), messages: messages, names: names, readUpTo: readUpTo, isGroup: stored?.isGroup ?? chat.hasSuffix("@g.us"),
            avatarURL: store.avatarURL(for: chat), avatars: avatars,
        )
    }

    func summary(for chat: WhatsAppChat) -> ChatSummary {
        let messages = store.messages(in: chat.jid)
        let last = messages.last
        var preview: String?
        if let last {
            let body = last.isDeleted ? "This message was deleted." : (last.text ?? last.label ?? "")
            if last.isFromMe {
                preview = "You: \(body)"
            } else if chat.isGroup {
                preview = "\(store.name(forUserJID: last.sender) ?? "Someone"): \(body)"
            } else {
                preview = body
            }
        }
        let unread: Int = if let readUpTo = chat.readUpTo {
            messages.count { !$0.isFromMe && $0.timestamp > readUpTo }
        } else {
            chat.unreadCount
        }
        return ChatSummary(
            id: "whatsapp:\(chat.jid)", network: .whatsapp, title: store.title(for: chat), avatarURL: store.avatarURL(for: chat.jid), avatarColorKey: chat.jid,
            preview: preview, timestamp: last?.timestamp ?? chat.lastTimestamp, unreadCount: max(unread, chat.markedUnread ? 1 : 0),
            destination: .whatsapp(jid: chat.jid), namesSenderInPreview: chat.isGroup, titleNamesPeople: !chat.isGroup,
            isMuted: chat.isMuted(),
        )
    }

    public func chatSummaries(for chats: Set<String>) -> [ChatSummary] {
        chats.compactMap { store.chat($0) }.map(summary(for:))
    }

    private func listPage() throws -> ChatListPage {
        reloadIfLinkedElsewhere()
        guard device?.jid != nil else { throw SourceError.notConfigured }
        // Chats without messages or a time are empty shells from app state, such as old mutes.
        store.mergeDuplicateChats()
        let chats = store.chats.filter { chat in
            !chat.jid.hasSuffix("@\(WhatsAppJID.Server.broadcast)") && !chat.jid.hasSuffix("@\(WhatsAppJID.Server.newsletter)")
                && (chat.lastTimestamp != nil || !store.messages(in: chat.jid).isEmpty)
        }
        let summaries = chats.map(summary(for:))
        let archived = Set(chats.filter(\.isArchived).map { "whatsapp:\($0.jid)" })
        return ChatListPage(chats: summaries.filter { !archived.contains($0.id) }, archived: summaries.filter { archived.contains($0.id) })
    }
}

extension WhatsAppClient: ChatListProvider {
    public nonisolated var chatNetwork: ChatNetwork {
        .whatsapp
    }

    public func chatList() async throws -> ChatListPage {
        try listPage()
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
