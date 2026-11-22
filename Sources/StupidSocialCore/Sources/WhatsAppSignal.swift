import Foundation

// The Signal protocol as WhatsApp linked devices use it: one-to-one sessions (X3DH and the double
// ratchet) and sender keys for groups. Ported from scripts/whatsapp-client.py, itself ported from
// libsignal-go (session/, ratchet/, groups/). Group sending, which the probe doesn't do, follows
// libsignal-go's groups/GroupSessionBuilder.go and groups/GroupCipher.go.

public enum WhatsAppSignalError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformedMessage
    case badPublicKey(length: Int)
    case noSession
    case noSignedPreKey(UInt32)
    case noOneTimePreKey(UInt32)
    case invalidSignedPreKeySignature
    case badMAC
    case badPadding
    /// The message key was already used or dropped: a duplicate delivery, which callers ignore.
    case oldCounter(counter: UInt32, current: UInt32)
    case tooFarIntoFuture
    /// No session state could decrypt the message; carries the last state's error.
    indirect case noValidSession(WhatsAppSignalError?)
    case noSenderKey
    case noSenderKeyState(id: UInt32)
    case badSenderKeySignature
}

// MARK: - State

/// Everything the Signal layer persists for an account, keyed by Signal address (`user[:device]@server`
/// as `JID.signal_address` in the probe makes it) and, for sender keys, `group|address`.
public struct WhatsAppSignalState: Codable, Equatable, Sendable {
    public var sessions: [String: WhatsAppSessionRecord] = [:]
    public var senderKeys: [String: [WhatsAppSenderKeyState]] = [:]
    /// Each address's 32-byte identity key, trusted on first use and replaced when it changes.
    public var identities: [String: Data] = [:]

    public init() {}
}

public struct WhatsAppSessionRecord: Codable, Equatable, Sendable {
    public static let maxArchivedStates = 40

    public var current: WhatsAppSessionState?
    public var previous: [WhatsAppSessionState] = []

    public init(current: WhatsAppSessionState? = nil, previous: [WhatsAppSessionState] = []) {
        self.current = current
        self.previous = previous
    }

    mutating func promote(_ state: WhatsAppSessionState) {
        if let current {
            previous.insert(current, at: 0)
            previous = Array(previous.prefix(Self.maxArchivedStates))
        }
        current = state
    }
}

public struct WhatsAppSessionState: Codable, Equatable, Sendable {
    public static let maxReceiverChains = 5

    public var version: Int
    /// 33-byte (type-prefixed) identity keys.
    public var remoteIdentity: Data
    public var localIdentity: Data
    public var rootKey: Data
    public var previousCounter: UInt32
    public var senderChain: SenderChain
    public var receiverChains: [ReceiverChain]
    public var pendingPreKey: PendingPreKey?
    public var localRegistrationId: UInt32
    public var remoteRegistrationId: UInt32
    /// The initiator's 33-byte base key, which identifies the session a prekey message belongs to.
    public var senderBaseKey: Data

    public struct SenderChain: Codable, Equatable, Sendable {
        public var ratchet: WhatsAppKeyPair
        public var key: Data
        public var index: UInt32
    }

    public struct ReceiverChain: Codable, Equatable, Sendable {
        public static let maxMessageKeys = 2000

        /// The sender's 32-byte ratchet public key.
        public var ratchet: Data
        public var key: Data
        public var index: UInt32
        /// Keys of skipped messages, oldest first.
        public var messageKeys: [MessageKeys]
    }

    public struct MessageKeys: Codable, Equatable, Sendable {
        public var index: UInt32
        public var cipherKey: Data
        public var macKey: Data
        public var iv: Data
    }

    /// Sent along with every message until the other side answers.
    public struct PendingPreKey: Codable, Equatable, Sendable {
        public var preKeyId: UInt32?
        public var signedPreKeyId: UInt32
        public var baseKey: Data
    }
}

public struct WhatsAppSenderKeyState: Codable, Equatable, Sendable {
    public static let maxStates = 5
    public static let maxMessageKeys = 2000

    public var id: UInt32
    public var iteration: UInt32
    public var chainKey: Data
    /// 32-byte public signing key.
    public var signingKey: Data
    /// Only present for our own sender key, which we sign with.
    public var signingPrivateKey: Data?
    /// Seeds of skipped messages, oldest first.
    public var messageKeys: [MessageKey] = []

    public struct MessageKey: Codable, Equatable, Sendable {
        public var iteration: UInt32
        public var seed: Data
    }
}

// MARK: - Keys the account owns

public struct WhatsAppSignedPreKey: Codable, Equatable, Sendable {
    public var id: UInt32
    public var keyPair: WhatsAppKeyPair
    public var signature: Data

    public init(id: UInt32, keyPair: WhatsAppKeyPair, signature: Data) {
        self.id = id
        self.keyPair = keyPair
        self.signature = signature
    }
}

/// A prekey bundle fetched for another device. Keys are 32 bytes (33 with the type prefix also works).
public struct WhatsAppPreKeyBundle: Equatable, Sendable {
    public var registrationId: UInt32
    public var identity: Data
    public var signedPreKeyId: UInt32
    public var signedPreKey: Data
    public var signature: Data
    public var preKeyId: UInt32?
    public var preKey: Data?

    public init(registrationId: UInt32, identity: Data, signedPreKeyId: UInt32, signedPreKey: Data, signature: Data, preKeyId: UInt32? = nil, preKey: Data? = nil) {
        self.registrationId = registrationId
        self.identity = identity
        self.signedPreKeyId = signedPreKeyId
        self.signedPreKey = signedPreKey
        self.signature = signature
        self.preKeyId = preKeyId
        self.preKey = preKey
    }
}

public struct WhatsAppPreKeyDecryption: Equatable, Sendable {
    public var plaintext: Data
    /// The one-time prekey the message consumed, which the caller deletes (and replenishes).
    public var usedPreKeyId: UInt32?
}

public enum WhatsAppEncryptedType: String, Sendable {
    case pkmsg
    case msg
}

// MARK: - Store

/// Sessions, identities and sender keys. The owner persists `state` after every mutating call that
/// returns successfully; a throwing call leaves the store unchanged.
public struct WhatsAppSignalStore: Sendable {
    public static let version = 3
    static let versionByte = UInt8(version << 4 | version)
    static let djbType: UInt8 = 5

    public var state: WhatsAppSignalState
    public var identity: WhatsAppKeyPair
    public var registrationId: UInt32
    public var signedPreKey: WhatsAppSignedPreKey
    /// Randomness for new keys and signatures; tests replace it to make output deterministic.
    var random: @Sendable (Int) -> Data = WhatsAppCipher.randomBytes

    public init(state: WhatsAppSignalState = WhatsAppSignalState(), identity: WhatsAppKeyPair, registrationId: UInt32, signedPreKey: WhatsAppSignedPreKey) {
        self.state = state
        self.identity = identity
        self.registrationId = registrationId
        self.signedPreKey = signedPreKey
    }

    // MARK: One-to-one sessions

    public func hasSession(address: String) -> Bool {
        state.sessions[address]?.current != nil
    }

    /// Decrypts a `pkmsg`, building a session from it unless one with its base key exists. An identity
    /// change is trusted, replacing the old session (whatsmeow's AutoTrustIdentity). With `keepState`
    /// false nothing is stored. `preKey` looks up our one-time prekeys by id.
    public mutating func decryptPreKeyMessage(address: String, _ raw: Data, keepState: Bool = true, preKey: (UInt32) -> WhatsAppKeyPair?) throws -> WhatsAppPreKeyDecryption {
        guard let first = raw.first else { throw WhatsAppSignalError.malformedMessage }
        guard Int(first >> 4) == Self.version else { throw WhatsAppSignalError.unsupportedVersion(Int(first >> 4)) }
        let message = try PreKeySignalMessage(raw.dropFirst())
        var record = state.sessions[address] ?? WhatsAppSessionRecord()
        let theirIdentity = try Self.undjb(message.identityKey)
        if let known = state.identities[address], known != theirIdentity {
            record = WhatsAppSessionRecord()
        }
        let usedPreKeyId = try processPreKeyMessage(&record, message, preKey: preKey)
        let plaintext = try decrypt(record: &record, message.message)
        if keepState {
            state.sessions[address] = record
            state.identities[address] = theirIdentity
        }
        return WhatsAppPreKeyDecryption(plaintext: plaintext, usedPreKeyId: usedPreKeyId)
    }

    /// Decrypts a `msg` with an existing session.
    public mutating func decryptMessage(address: String, _ raw: Data) throws -> Data {
        guard var record = state.sessions[address] else { throw WhatsAppSignalError.noSession }
        let plaintext = try decrypt(record: &record, raw)
        state.sessions[address] = record
        return plaintext
    }

    /// X3DH as the initiator from a fetched prekey bundle (libsignal-go Builder.ProcessBundle).
    public mutating func buildSession(address: String, bundle: WhatsAppPreKeyBundle) throws {
        let theirIdentity = try Self.undjb(bundle.identity)
        let theirSignedPreKey = try Self.undjb(bundle.signedPreKey)
        guard WhatsAppXEdDSA.verify(publicKey: theirIdentity, message: Self.djb(theirSignedPreKey), signature: bundle.signature) else {
            throw WhatsAppSignalError.invalidSignedPreKeySignature
        }
        var record = state.sessions[address] ?? WhatsAppSessionRecord()
        let base = WhatsAppKeyPair.generate(random: random)
        var secrets = try Data(repeating: 0xFF, count: 32)
            + identity.agree(with: theirSignedPreKey)
            + base.agree(with: theirIdentity)
            + base.agree(with: theirSignedPreKey)
        if let preKey = bundle.preKey {
            secrets += try base.agree(with: Self.undjb(preKey))
        }
        let derived = WhatsAppCipher.hkdf(secrets, length: 64, info: Data("WhisperText".utf8))
        let sending = WhatsAppKeyPair.generate(random: random)
        let (rootKey, sendingKey) = try Self.rootCreateChain(rootKey: derived.prefix(32), theirRatchet: theirSignedPreKey, ourRatchet: sending)
        record.promote(WhatsAppSessionState(
            version: Self.version,
            remoteIdentity: Self.djb(theirIdentity),
            localIdentity: Self.djb(identity.publicKey),
            rootKey: rootKey,
            previousCounter: 0,
            senderChain: .init(ratchet: sending, key: sendingKey, index: 0),
            receiverChains: [.init(ratchet: theirSignedPreKey, key: derived.suffix(32), index: 0, messageKeys: [])],
            pendingPreKey: .init(preKeyId: bundle.preKeyId, signedPreKeyId: bundle.signedPreKeyId, baseKey: Self.djb(base.publicKey)),
            localRegistrationId: registrationId,
            remoteRegistrationId: bundle.registrationId,
            senderBaseKey: Self.djb(base.publicKey),
        ))
        state.sessions[address] = record
        state.identities[address] = theirIdentity
    }

    /// Encrypts with the current session and advances its sending chain. The result is a `pkmsg` until
    /// the other side has answered.
    public mutating func encrypt(address: String, _ plaintext: Data) throws -> (type: WhatsAppEncryptedType, data: Data) {
        guard var record = state.sessions[address], var session = record.current else { throw WhatsAppSignalError.noSession }
        let chain = session.senderChain
        let keys = Self.messageKeys(chainKey: chain.key, index: chain.index)
        var body = ProtoMessage()
        body.set(1, Self.djb(chain.ratchet.publicKey))
        body.set(2, chain.index)
        body.set(3, session.previousCounter)
        try body.set(4, Self.cbcEncrypt(key: keys.cipherKey, iv: keys.iv, plaintext))
        let serialized = Data([Self.versionByte]) + body.serialized()
        let mac = WhatsAppCipher.hmacSHA256(key: keys.macKey, session.localIdentity + session.remoteIdentity + serialized).prefix(8)
        var result: (type: WhatsAppEncryptedType, data: Data) = (.msg, serialized + mac)
        if let pending = session.pendingPreKey {
            var message = ProtoMessage()
            if let preKeyId = pending.preKeyId { message.set(1, preKeyId) }
            message.set(2, pending.baseKey)
            message.set(3, session.localIdentity)
            message.set(4, result.data)
            message.set(5, session.localRegistrationId)
            message.set(6, pending.signedPreKeyId)
            result = (.pkmsg, Data([Self.versionByte]) + message.serialized())
        }
        session.senderChain.key = Self.chainNext(chain.key)
        session.senderChain.index += 1
        record.current = session
        state.sessions[address] = record
        return result
    }

    private func processPreKeyMessage(_ record: inout WhatsAppSessionRecord, _ message: PreKeySignalMessage, preKey: (UInt32) -> WhatsAppKeyPair?) throws -> UInt32? {
        let states = [record.current].compactMap(\.self) + record.previous
        if states.contains(where: { $0.version == Self.version && $0.senderBaseKey == message.baseKey }) {
            return nil
        }
        guard message.signedPreKeyId == signedPreKey.id else { throw WhatsAppSignalError.noSignedPreKey(message.signedPreKeyId) }
        let ourSigned = signedPreKey.keyPair
        let theirBase = try Self.undjb(message.baseKey)
        let theirIdentity = try Self.undjb(message.identityKey)
        var secrets = try Data(repeating: 0xFF, count: 32)
            + ourSigned.agree(with: theirIdentity)
            + identity.agree(with: theirBase)
            + ourSigned.agree(with: theirBase)
        let preKeyId = message.preKeyId.flatMap { $0 == 0 ? nil : $0 }
        if let preKeyId {
            guard let oneTime = preKey(preKeyId) else { throw WhatsAppSignalError.noOneTimePreKey(preKeyId) }
            secrets += try oneTime.agree(with: theirBase)
        }
        let derived = WhatsAppCipher.hkdf(secrets, length: 64, info: Data("WhisperText".utf8))
        record.promote(WhatsAppSessionState(
            version: Self.version,
            remoteIdentity: Self.djb(theirIdentity),
            localIdentity: Self.djb(identity.publicKey),
            rootKey: derived.prefix(32),
            previousCounter: 0,
            senderChain: .init(ratchet: ourSigned, key: derived.suffix(32), index: 0),
            receiverChains: [],
            pendingPreKey: nil,
            localRegistrationId: registrationId,
            remoteRegistrationId: message.registrationId,
            senderBaseKey: message.baseKey,
        ))
        return preKeyId
    }

    /// Tries the current state, then archived ones; the state that decrypts becomes current.
    private func decrypt(record: inout WhatsAppSessionRecord, _ raw: Data) throws -> Data {
        let candidates = [record.current] + record.previous.map(Optional.some)
        var lastError: WhatsAppSignalError?
        for (index, candidate) in candidates.enumerated() {
            guard var attempt = candidate else { continue }
            let plaintext: Data
            do {
                plaintext = try decrypt(state: &attempt, raw)
            } catch let error as WhatsAppSignalError {
                if case .oldCounter = error { throw error }
                lastError = error
                continue
            } catch {
                lastError = .malformedMessage
                continue
            }
            if index == 0 {
                record.current = attempt
            } else {
                record.previous.remove(at: index - 1)
                if let current = record.current { record.previous.insert(current, at: 0) }
                record.current = attempt
            }
            return plaintext
        }
        throw WhatsAppSignalError.noValidSession(lastError)
    }

    private func decrypt(state session: inout WhatsAppSessionState, _ raw: Data) throws -> Data {
        guard raw.count > 9 else { throw WhatsAppSignalError.malformedMessage }
        guard Int(raw[raw.startIndex] >> 4) == session.version else { throw WhatsAppSignalError.unsupportedVersion(Int(raw[raw.startIndex] >> 4)) }
        let signed = raw.dropLast(8)
        let message = try SignalMessage(signed.dropFirst())
        let theirRatchet = try Self.undjb(message.ratchetKey)
        let chainIndex = try receiverChain(&session, theirRatchet: theirRatchet)
        let keys = try Self.messageKeys(&session.receiverChains[chainIndex], counter: message.counter)
        let mac = WhatsAppCipher.hmacSHA256(key: keys.macKey, session.remoteIdentity + session.localIdentity + signed).prefix(8)
        guard Self.constantTimeEqual(mac, raw.suffix(8)) else { throw WhatsAppSignalError.badMAC }
        let plaintext = try Self.cbcDecrypt(key: keys.cipherKey, iv: keys.iv, message.ciphertext)
        session.pendingPreKey = nil
        return plaintext
    }

    /// The receiver chain for a ratchet key, stepping the root ratchet when the key is new.
    private func receiverChain(_ session: inout WhatsAppSessionState, theirRatchet: Data) throws -> Int {
        if let index = session.receiverChains.firstIndex(where: { $0.ratchet == theirRatchet }) {
            return index
        }
        let sender = session.senderChain
        let (rootKey, receivingKey) = try Self.rootCreateChain(rootKey: session.rootKey, theirRatchet: theirRatchet, ourRatchet: sender.ratchet)
        let newRatchet = WhatsAppKeyPair.generate(random: random)
        let (nextRootKey, sendingKey) = try Self.rootCreateChain(rootKey: rootKey, theirRatchet: theirRatchet, ourRatchet: newRatchet)
        session.rootKey = nextRootKey
        session.receiverChains.append(.init(ratchet: theirRatchet, key: receivingKey, index: 0, messageKeys: []))
        session.receiverChains = Array(session.receiverChains.suffix(WhatsAppSessionState.maxReceiverChains))
        session.previousCounter = sender.index > 0 ? sender.index - 1 : 0
        session.senderChain = .init(ratchet: newRatchet, key: sendingKey, index: 0)
        return session.receiverChains.count - 1
    }

    private static func messageKeys(_ chain: inout WhatsAppSessionState.ReceiverChain, counter: UInt32) throws -> WhatsAppSessionState.MessageKeys {
        if chain.index > counter {
            guard let index = chain.messageKeys.firstIndex(where: { $0.index == counter }) else {
                throw WhatsAppSignalError.oldCounter(counter: counter, current: chain.index)
            }
            return chain.messageKeys.remove(at: index)
        }
        guard counter - chain.index <= WhatsAppSessionState.ReceiverChain.maxMessageKeys else { throw WhatsAppSignalError.tooFarIntoFuture }
        while chain.index < counter {
            chain.messageKeys.append(messageKeys(chainKey: chain.key, index: chain.index))
            if chain.messageKeys.count > WhatsAppSessionState.ReceiverChain.maxMessageKeys {
                chain.messageKeys.removeFirst(chain.messageKeys.count - WhatsAppSessionState.ReceiverChain.maxMessageKeys)
            }
            chain.key = chainNext(chain.key)
            chain.index += 1
        }
        let keys = messageKeys(chainKey: chain.key, index: chain.index)
        chain.key = chainNext(chain.key)
        chain.index += 1
        return keys
    }

    // MARK: Sender keys (groups)

    /// Stores a sender key another device distributed for a group (libsignal-go SessionBuilder.Process).
    public mutating func processSenderKeyDistribution(group: String, address: String, _ raw: Data) throws {
        guard !raw.isEmpty else { throw WhatsAppSignalError.malformedMessage }
        let message = try WhatsAppSignalStore.decode(raw.dropFirst())
        guard let chainKey = message.data(3), let signingKey = message.data(4) else { throw WhatsAppSignalError.malformedMessage }
        let name = Self.senderKeyName(group: group, address: address)
        let newState = try WhatsAppSenderKeyState(
            id: message.uint32(1) ?? 0,
            iteration: message.uint32(2) ?? 0,
            chainKey: chainKey,
            signingKey: Self.undjb(signingKey),
        )
        state.senderKeys[name] = Array(([newState] + (state.senderKeys[name] ?? [])).prefix(WhatsAppSenderKeyState.maxStates))
    }

    public mutating func decryptGroupMessage(group: String, address: String, _ raw: Data) throws -> Data {
        let name = Self.senderKeyName(group: group, address: address)
        guard var states = state.senderKeys[name], !states.isEmpty else { throw WhatsAppSignalError.noSenderKey }
        guard raw.count > 65 else { throw WhatsAppSignalError.malformedMessage }
        let signed = raw.dropLast(64)
        let message = try WhatsAppSignalStore.decode(signed.dropFirst())
        let id = message.uint32(1) ?? 0
        guard let index = states.firstIndex(where: { $0.id == id }) else { throw WhatsAppSignalError.noSenderKeyState(id: id) }
        guard WhatsAppXEdDSA.verify(publicKey: states[index].signingKey, message: signed, signature: raw.suffix(64)) else {
            throw WhatsAppSignalError.badSenderKeySignature
        }
        var attempt = states[index]
        let seed = try Self.senderMessageSeed(&attempt, iteration: message.uint32(2) ?? 0)
        let derived = WhatsAppCipher.hkdf(seed, length: 48, info: Data("WhisperGroup".utf8))
        let plaintext = try Self.cbcDecrypt(key: derived.suffix(32), iv: derived.prefix(16), message.data(3) ?? Data())
        states[index] = attempt
        state.senderKeys[name] = states
        return plaintext
    }

    /// The SenderKeyDistributionMessage for our sender key in a group, creating the key when there is
    /// none (libsignal-go SessionBuilder.Create).
    public mutating func senderKeyDistribution(group: String, ownAddress: String) -> Data {
        let name = Self.senderKeyName(group: group, address: ownAddress)
        if state.senderKeys[name]?.first?.signingPrivateKey == nil {
            let signing = WhatsAppKeyPair.generate(random: random)
            // A 31-bit id, as WhatsApp Web and Baileys generate it.
            let id = random(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF
            state.senderKeys[name] = [WhatsAppSenderKeyState(
                id: id,
                iteration: 0,
                chainKey: random(32),
                signingKey: signing.publicKey,
                signingPrivateKey: signing.privateKey,
            )]
        }
        let own = state.senderKeys[name]![0]
        var message = ProtoMessage()
        message.set(1, own.id)
        message.set(2, own.iteration)
        message.set(3, own.chainKey)
        message.set(4, Self.djb(own.signingKey))
        return Data([Self.versionByte]) + message.serialized()
    }

    /// A SenderKeyMessage for the group, signed with our sender key, advancing its chain. Call
    /// `senderKeyDistribution(group:ownAddress:)` first.
    public mutating func encryptGroupMessage(group: String, ownAddress: String, _ plaintext: Data) throws -> Data {
        let name = Self.senderKeyName(group: group, address: ownAddress)
        guard var own = state.senderKeys[name]?.first, let signingPrivateKey = own.signingPrivateKey else { throw WhatsAppSignalError.noSenderKey }
        let seed = WhatsAppCipher.hmacSHA256(key: own.chainKey, Data([1]))
        let derived = WhatsAppCipher.hkdf(seed, length: 48, info: Data("WhisperGroup".utf8))
        var message = ProtoMessage()
        message.set(1, own.id)
        message.set(2, own.iteration)
        try message.set(3, Self.cbcEncrypt(key: derived.suffix(32), iv: derived.prefix(16), plaintext))
        let serialized = Data([Self.versionByte]) + message.serialized()
        let signature = WhatsAppXEdDSA.sign(privateKey: signingPrivateKey, message: serialized, random: random(64))
        own.chainKey = WhatsAppCipher.hmacSHA256(key: own.chainKey, Data([2]))
        own.iteration += 1
        state.senderKeys[name]![0] = own
        return serialized + signature
    }

    private static func senderKeyName(group: String, address: String) -> String {
        "\(group)|\(address)"
    }

    private static func senderMessageSeed(_ state: inout WhatsAppSenderKeyState, iteration: UInt32) throws -> Data {
        if state.iteration > iteration {
            guard let index = state.messageKeys.firstIndex(where: { $0.iteration == iteration }) else {
                throw WhatsAppSignalError.oldCounter(counter: iteration, current: state.iteration)
            }
            return state.messageKeys.remove(at: index).seed
        }
        guard iteration - state.iteration <= WhatsAppSenderKeyState.maxMessageKeys else { throw WhatsAppSignalError.tooFarIntoFuture }
        while state.iteration < iteration {
            state.messageKeys.append(.init(iteration: state.iteration, seed: WhatsAppCipher.hmacSHA256(key: state.chainKey, Data([1]))))
            if state.messageKeys.count > WhatsAppSenderKeyState.maxMessageKeys {
                state.messageKeys.removeFirst(state.messageKeys.count - WhatsAppSenderKeyState.maxMessageKeys)
            }
            state.chainKey = WhatsAppCipher.hmacSHA256(key: state.chainKey, Data([2]))
            state.iteration += 1
        }
        let seed = WhatsAppCipher.hmacSHA256(key: state.chainKey, Data([1]))
        state.chainKey = WhatsAppCipher.hmacSHA256(key: state.chainKey, Data([2]))
        state.iteration += 1
        return seed
    }

    // MARK: Primitives

    static func decode(_ data: Data) throws -> ProtoMessage {
        do {
            return try ProtoMessage(data)
        } catch {
            throw WhatsAppSignalError.malformedMessage
        }
    }

    static func djb(_ publicKey: Data) -> Data {
        Data([djbType]) + publicKey
    }

    static func undjb(_ publicKey: Data) throws -> Data {
        if publicKey.count == 33, publicKey.first == djbType { return Data(publicKey.dropFirst()) }
        if publicKey.count == 32 { return Data(publicKey) }
        throw WhatsAppSignalError.badPublicKey(length: publicKey.count)
    }

    static func messageKeys(chainKey: Data, index: UInt32) -> WhatsAppSessionState.MessageKeys {
        let material = WhatsAppCipher.hkdf(WhatsAppCipher.hmacSHA256(key: chainKey, Data([1])), length: 80, info: Data("WhisperMessageKeys".utf8))
        return .init(index: index, cipherKey: material.prefix(32), macKey: material.dropFirst(32).prefix(32), iv: material.suffix(16))
    }

    static func chainNext(_ chainKey: Data) -> Data {
        WhatsAppCipher.hmacSHA256(key: chainKey, Data([2]))
    }

    /// (new root key, new chain key).
    static func rootCreateChain(rootKey: Data, theirRatchet: Data, ourRatchet: WhatsAppKeyPair) throws -> (Data, Data) {
        let derived = try WhatsAppCipher.hkdf(ourRatchet.agree(with: theirRatchet), length: 64, salt: rootKey, info: Data("WhisperRatchet".utf8))
        return (derived.prefix(32), derived.suffix(32))
    }

    private static func cbcEncrypt(key: Data, iv: Data, _ plaintext: Data) throws -> Data {
        try WhatsAppCipher.aesCBCEncrypt(key: Data(key), iv: Data(iv), plaintext)
    }

    private static func cbcDecrypt(key: Data, iv: Data, _ ciphertext: Data) throws -> Data {
        do {
            return try WhatsAppCipher.aesCBCDecrypt(key: Data(key), iv: Data(iv), ciphertext)
        } catch {
            throw WhatsAppSignalError.badPadding
        }
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - Whisper messages (libsignal-go serialize/WhisperTextProtocol.proto)

private struct SignalMessage {
    var ratchetKey: Data
    var counter: UInt32
    var previousCounter: UInt32
    var ciphertext: Data

    init(_ data: Data) throws {
        let message = try WhatsAppSignalStore.decode(data)
        guard let ratchetKey = message.data(1), let ciphertext = message.data(4) else { throw WhatsAppSignalError.malformedMessage }
        self.ratchetKey = ratchetKey
        counter = message.uint32(2) ?? 0
        previousCounter = message.uint32(3) ?? 0
        self.ciphertext = ciphertext
    }
}

private struct PreKeySignalMessage {
    var registrationId: UInt32
    var preKeyId: UInt32?
    var signedPreKeyId: UInt32
    var baseKey: Data
    var identityKey: Data
    var message: Data

    init(_ data: Data) throws {
        let message = try WhatsAppSignalStore.decode(data)
        guard let baseKey = message.data(2), let identityKey = message.data(3), let inner = message.data(4) else {
            throw WhatsAppSignalError.malformedMessage
        }
        registrationId = message.uint32(5) ?? 0
        preKeyId = message.uint32(1)
        signedPreKeyId = message.uint32(6) ?? 0
        self.baseKey = baseKey
        self.identityKey = identityKey
        self.message = inner
    }
}

// MARK: - Message padding

/// WhatsApp pads message plaintext before Signal encryption (whatsmeow padMessage/unpadMessage).
public enum WhatsAppMessagePadding {
    /// Appends 1 to 15 bytes, each holding the pad length.
    public static func pad(_ plaintext: Data) -> Data {
        var count = UInt8.random(in: 0 ..< 16)
        if count == 0 { count = 15 }
        return plaintext + Data(repeating: count, count: Int(count))
    }

    /// `version` is the `enc` node's `v` attribute; version 3 payloads are not padded.
    public static func unpad(_ plaintext: Data, version: Int) throws -> Data {
        if version == 3 { return plaintext }
        guard let count = plaintext.last.map(Int.init) else { throw WhatsAppSignalError.badPadding }
        guard count > 0, plaintext.count >= count, plaintext.suffix(count).allSatisfy({ $0 == UInt8(count) }) else {
            throw WhatsAppSignalError.badPadding
        }
        return plaintext.dropLast(count)
    }
}
