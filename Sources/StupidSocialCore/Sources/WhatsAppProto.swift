import CryptoKit
import Foundation

/// A hand-modelled protobuf message: decoded from the wire format by `ProtoMessage`.
public protocol WhatsAppProtoDecodable: Sendable {
    init(proto: ProtoMessage)
}

public extension WhatsAppProtoDecodable {
    init(data: Data) throws {
        try self.init(proto: ProtoMessage(data))
    }
}

/// A hand-modelled protobuf message the client sends; fields are set in field-number order, as the
/// Python and Go encoders write them.
public protocol WhatsAppProtoEncodable: Sendable {
    var proto: ProtoMessage { get }
}

public extension WhatsAppProtoEncodable {
    func serialized() -> Data {
        proto.serialized()
    }
}

/// The WhatsApp protobuf messages the app uses, with field numbers from whatsmeow's .proto files
/// (third-party/whatsmeow/proto). Only the fields the app needs are modelled.
public enum WhatsAppProto {}

// MARK: - waWa6 (Noise handshake and login)

public extension WhatsAppProto {
    /// waWa6 `HandshakeMessage`.
    struct HandshakeMessage: WhatsAppProtoDecodable, WhatsAppProtoEncodable, Equatable {
        /// `HandshakeMessage.ClientHello`.
        public struct ClientHello: Sendable, Equatable {
            public var ephemeral: Data
        }

        /// `HandshakeMessage.ServerHello`.
        public struct ServerHello: Sendable, Equatable {
            public var ephemeral: Data
            public var staticKey: Data
            public var payload: Data
        }

        /// `HandshakeMessage.ClientFinish`.
        public struct ClientFinish: Sendable, Equatable {
            public var staticKey: Data
            public var payload: Data
        }

        public var clientHello: ClientHello?
        public var serverHello: ServerHello?
        public var clientFinish: ClientFinish?

        public init(clientHello: ClientHello? = nil, serverHello: ServerHello? = nil, clientFinish: ClientFinish? = nil) {
            self.clientHello = clientHello
            self.serverHello = serverHello
            self.clientFinish = clientFinish
        }

        public init(proto: ProtoMessage) {
            clientHello = proto.message(2).map { ClientHello(ephemeral: $0.data(1) ?? Data()) }
            serverHello = proto.message(3).map { ServerHello(ephemeral: $0.data(1) ?? Data(), staticKey: $0.data(2) ?? Data(), payload: $0.data(3) ?? Data()) }
            clientFinish = proto.message(4).map { ClientFinish(staticKey: $0.data(1) ?? Data(), payload: $0.data(2) ?? Data()) }
        }

        public var proto: ProtoMessage {
            var message = ProtoMessage()
            if let clientHello {
                var hello = ProtoMessage()
                hello.set(1, clientHello.ephemeral)
                message.set(2, hello)
            }
            if let serverHello {
                var hello = ProtoMessage()
                hello.set(1, serverHello.ephemeral)
                hello.set(2, serverHello.staticKey)
                hello.set(3, serverHello.payload)
                message.set(3, hello)
            }
            if let clientFinish {
                var finish = ProtoMessage()
                finish.set(1, clientFinish.staticKey)
                finish.set(2, clientFinish.payload)
                message.set(4, finish)
            }
            return message
        }
    }

    /// A web client version, as `ClientPayload.UserAgent.AppVersion` and `DeviceProps.AppVersion` carry it.
    struct AppVersion: Sendable, Equatable, Codable {
        public var primary: UInt32
        public var secondary: UInt32
        public var tertiary: UInt32

        public init(_ primary: UInt32, _ secondary: UInt32, _ tertiary: UInt32) {
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
        }

        /// The version whatsmeow ships; the current one is `client_revision` in web.whatsapp.com/sw.js.
        public static let `default` = AppVersion(2, 3000, 1_050_728_964)

        var proto: ProtoMessage {
            var message = ProtoMessage()
            message.set(1, primary)
            message.set(2, secondary)
            message.set(3, tertiary)
            return message
        }
    }

    /// waWa6 `ClientPayload` (whatsmeow store/clientpayload.go): a Safari web client logging in or registering.
    struct ClientPayload: WhatsAppProtoEncodable {
        public enum Mode: Sendable {
            /// Logging in as a linked device (`username` is the phone number user part).
            case login(username: UInt64, device: UInt32)
            case registration(DevicePairingRegistrationData)
        }

        public var version: AppVersion
        public var mode: Mode

        public init(version: AppVersion, mode: Mode) {
            self.version = version
            self.mode = mode
        }

        public var proto: ProtoMessage {
            var payload = ProtoMessage()
            switch mode {
            case let .login(username, _):
                payload.set(1, username)
                payload.set(3, true)
            case .registration:
                payload.set(3, false)
            }
            var agent = ProtoMessage()
            agent.set(1, UInt64(14)) // Platform.WEB
            agent.set(2, version.proto)
            agent.set(3, "000")
            agent.set(4, "000")
            agent.set(5, "0.1")
            agent.set(6, "")
            agent.set(7, "Desktop")
            agent.set(8, "0.1")
            agent.set(10, UInt64(0)) // ReleaseChannel.RELEASE
            agent.set(11, "en")
            agent.set(12, "US")
            payload.set(5, agent)
            var webInfo = ProtoMessage()
            webInfo.set(4, UInt64(0)) // WebSubPlatform.WEB_BROWSER
            payload.set(6, webInfo)
            payload.set(12, UInt64(1)) // ConnectType.WIFI_UNKNOWN
            payload.set(13, UInt64(1)) // ConnectReason.USER_ACTIVATED
            switch mode {
            case let .login(_, device):
                payload.set(18, device)
                payload.set(24, UInt64(1)) // lc
                payload.set(33, true) // pull
                payload.set(41, true) // lidDbMigrated
            case let .registration(registration):
                payload.set(19, registration.proto(buildHash: Self.buildHash(version)))
                payload.set(33, false)
            }
            return payload
        }

        /// MD5 of the dotted version, as whatsmeow computes `buildHash`.
        static func buildHash(_ version: AppVersion) -> Data {
            Data(Insecure.MD5.hash(data: Data("\(version.primary).\(version.secondary).\(version.tertiary)".utf8)))
        }
    }

    /// waWa6 `ClientPayload.DevicePairingRegistrationData`, from the new device's Signal keys.
    struct DevicePairingRegistrationData: Sendable {
        public var registrationID: UInt32
        /// The 32-byte Curve25519 identity public key.
        public var identityKey: Data
        public var signedPreKeyID: UInt32
        public var signedPreKey: Data
        public var signedPreKeySignature: Data
        public var deviceProps: DeviceProps

        public init(registrationID: UInt32, identityKey: Data, signedPreKeyID: UInt32, signedPreKey: Data, signedPreKeySignature: Data, deviceProps: DeviceProps = DeviceProps()) {
            self.registrationID = registrationID
            self.identityKey = identityKey
            self.signedPreKeyID = signedPreKeyID
            self.signedPreKey = signedPreKey
            self.signedPreKeySignature = signedPreKeySignature
            self.deviceProps = deviceProps
        }

        func proto(buildHash: Data) -> ProtoMessage {
            var message = ProtoMessage()
            message.set(1, bigEndian(registrationID, count: 4))
            message.set(2, Data([5])) // DJB key type
            message.set(3, identityKey)
            message.set(4, bigEndian(signedPreKeyID, count: 3))
            message.set(5, signedPreKey)
            message.set(6, signedPreKeySignature)
            message.set(7, buildHash)
            message.set(8, deviceProps.serialized())
            return message
        }

        private func bigEndian(_ value: UInt32, count: Int) -> Data {
            Data((0 ..< count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
    }

    /// waCompanionReg `DeviceProps`: how the linked device shows in WhatsApp → Linked devices, and the
    /// history sync it asks for.
    struct DeviceProps: WhatsAppProtoEncodable {
        public var os: String
        public var version: AppVersion
        /// `DeviceProps.PlatformType`; 5 is SAFARI.
        public var platformType: UInt64

        public init(os: String = "stupid social", version: AppVersion = AppVersion(0, 1, 0), platformType: UInt64 = 5) {
            self.os = os
            self.version = version
            self.platformType = platformType
        }

        public var proto: ProtoMessage {
            var props = ProtoMessage()
            props.set(1, os)
            props.set(2, version.proto)
            props.set(3, platformType)
            props.set(4, false) // requireFullSync
            var sync = ProtoMessage()
            sync.set(3, UInt64(10240)) // storageQuotaMb
            sync.set(4, true) // inlineInitialPayloadInE2EeMsg
            sync.set(6, false) // supportCallLogHistory
            sync.set(7, true) // supportBotUserAgentChatHistory
            sync.set(8, true) // supportCagReactionsAndPolls
            sync.set(9, true) // supportBizHostedMsg
            sync.set(10, true) // supportRecentSyncChunkMessageCountTuning
            sync.set(11, true) // supportHostedGroupMsg
            sync.set(12, true) // supportFbidBotChatHistory
            sync.set(14, true) // supportMessageAssociation
            sync.set(15, true) // supportGroupHistory
            sync.set(19, UInt64(60)) // thumbnailSyncDaysLimit
            props.set(5, sync)
            return props
        }
    }
}

// MARK: - waCert

public extension WhatsAppProto {
    /// waCert `CertChain`: the server's Noise certificate chain.
    struct CertChain: WhatsAppProtoDecodable, Equatable {
        /// `CertChain.NoiseCertificate`; `details` is a serialized `Details`, signed by the issuer.
        public struct NoiseCertificate: Sendable, Equatable {
            public var details: Data
            public var signature: Data

            init(proto: ProtoMessage) {
                details = proto.data(1) ?? Data()
                signature = proto.data(2) ?? Data()
            }
        }

        /// `CertChain.NoiseCertificate.Details`.
        public struct Details: WhatsAppProtoDecodable, Equatable {
            public var serial: UInt32
            public var issuerSerial: UInt32
            public var key: Data
            public var notBefore: UInt64
            public var notAfter: UInt64

            public init(proto: ProtoMessage) {
                serial = proto.uint32(1) ?? 0
                issuerSerial = proto.uint32(2) ?? 0
                key = proto.data(3) ?? Data()
                notBefore = proto.uint64(4) ?? 0
                notAfter = proto.uint64(5) ?? 0
            }
        }

        public var leaf: NoiseCertificate?
        public var intermediate: NoiseCertificate?

        public init(proto: ProtoMessage) {
            leaf = proto.message(1).map(NoiseCertificate.init)
            intermediate = proto.message(2).map(NoiseCertificate.init)
        }
    }
}

// MARK: - waAdv (pairing)

public extension WhatsAppProto {
    /// waAdv `ADVEncryptionType`.
    enum ADVEncryptionType: UInt64, Sendable {
        case e2ee = 0
        case hosted = 1
    }

    /// waAdv `ADVSignedDeviceIdentityHMAC`, in `pair-success`'s `device-identity`.
    struct ADVSignedDeviceIdentityHMAC: WhatsAppProtoDecodable, Equatable {
        public var details: Data
        public var hmac: Data
        public var accountType: ADVEncryptionType?

        public init(proto: ProtoMessage) {
            details = proto.data(1) ?? Data()
            hmac = proto.data(2) ?? Data()
            accountType = proto.uint64(3).flatMap(ADVEncryptionType.init)
        }
    }

    /// waAdv `ADVSignedDeviceIdentity`. Backed by the decoded message so it re-serializes with every field it
    /// came with: the client sets `deviceSignature`, stores it, then clears `accountSignatureKey` for the server.
    struct ADVSignedDeviceIdentity: WhatsAppProtoDecodable, WhatsAppProtoEncodable, Equatable {
        public private(set) var proto: ProtoMessage

        public init(proto: ProtoMessage) {
            self.proto = proto
        }

        /// A serialized `ADVDeviceIdentity`.
        public var details: Data? {
            get { proto.data(1) }
            set { replace(1, newValue) }
        }

        public var accountSignatureKey: Data? {
            get { proto.data(2) }
            set { replace(2, newValue) }
        }

        public var accountSignature: Data? {
            get { proto.data(3) }
            set { replace(3, newValue) }
        }

        public var deviceSignature: Data? {
            get { proto.data(4) }
            set { replace(4, newValue) }
        }

        /// Sets or clears a field, keeping the fields in field-number order like the generated encoders.
        private mutating func replace(_ number: Int, _ value: Data?) {
            var field = ProtoMessage()
            if let value { field.set(number, value) }
            var data = Data()
            var written = false
            for existing in proto.fields where existing.number != number {
                if !written, existing.number > number {
                    data += field.serialized()
                    written = true
                }
                data += ProtoMessage.serialize(existing)
            }
            if !written {
                data += field.serialized()
            }
            // Re-reading what was just written from valid fields can't fail.
            proto = try! ProtoMessage(data)
        }
    }

    /// waAdv `ADVDeviceIdentity`.
    struct ADVDeviceIdentity: WhatsAppProtoDecodable, Equatable {
        public var rawID: UInt32
        public var timestamp: UInt64
        public var keyIndex: UInt32
        public var accountType: ADVEncryptionType?
        public var deviceType: ADVEncryptionType?

        public init(proto: ProtoMessage) {
            rawID = proto.uint32(1) ?? 0
            timestamp = proto.uint64(2) ?? 0
            keyIndex = proto.uint32(3) ?? 0
            accountType = proto.uint64(4).flatMap(ADVEncryptionType.init)
            deviceType = proto.uint64(5).flatMap(ADVEncryptionType.init)
        }
    }
}

extension ProtoMessage {
    /// One field in the wire format.
    static func serialize(_ field: (number: Int, value: Value)) -> Data {
        var output = Data()
        switch field.value {
        case let .varint(value):
            writeVarint(UInt64(field.number << 3), into: &output)
            writeVarint(value, into: &output)
        case let .fixed64(value):
            writeVarint(UInt64(field.number << 3 | 1), into: &output)
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        case let .bytes(data):
            writeVarint(UInt64(field.number << 3 | 2), into: &output)
            writeVarint(UInt64(data.count), into: &output)
            output.append(data)
        case let .fixed32(value):
            writeVarint(UInt64(field.number << 3 | 5), into: &output)
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }
}

// MARK: - waCommon

public extension WhatsAppProto {
    /// waCommon `MessageKey`.
    struct MessageKey: WhatsAppProtoDecodable, WhatsAppProtoEncodable, Equatable, Hashable {
        public var remoteJID: String?
        public var fromMe: Bool?
        public var id: String?
        public var participant: String?

        public init(remoteJID: String?, fromMe: Bool?, id: String?, participant: String? = nil) {
            self.remoteJID = remoteJID
            self.fromMe = fromMe
            self.id = id
            self.participant = participant
        }

        public init(proto: ProtoMessage) {
            remoteJID = proto.string(1)
            fromMe = proto.bool(2)
            id = proto.string(3)
            participant = proto.string(4)
        }

        public var proto: ProtoMessage {
            var message = ProtoMessage()
            message.set(1, ifPresent: remoteJID)
            if let fromMe { message.set(2, fromMe) }
            message.set(3, ifPresent: id)
            message.set(4, ifPresent: participant)
            return message
        }
    }
}

// MARK: - waE2E

public extension WhatsAppProto {
    /// waE2E `Message`. Backed by the decoded message so quoted messages and forwarded content re-serialize
    /// as they came; the accessors decode on read.
    struct Message: WhatsAppProtoDecodable, WhatsAppProtoEncodable, Equatable {
        public let proto: ProtoMessage

        public init(proto: ProtoMessage) {
            self.proto = proto
        }

        enum Field {
            static let conversation = 1
            static let senderKeyDistribution = 2
            static let image = 3
            static let contact = 4
            static let location = 5
            static let extendedText = 6
            static let document = 7
            static let audio = 8
            static let video = 9
            static let protocolMessage = 12
            static let contactsArray = 13
            static let liveLocation = 18
            static let sticker = 26
            static let deviceSent = 31
            static let messageContextInfo = 35
            static let viewOnce = 37
            static let ephemeral = 40
            static let reaction = 46
            static let pollCreation = 49
            static let documentWithCaption = 53
            static let viewOnceV2 = 55
            static let edited = 58
            static let viewOnceV2Extension = 59
            static let pollCreationV2 = 60
            static let pollCreationV3 = 64

            /// `FutureProofMessage` wrappers whose `message` is the content (whatsmeow UnwrapRaw).
            static let wrappers = [ephemeral, viewOnce, viewOnceV2, viewOnceV2Extension, documentWithCaption, edited]
            static let modelled = Set(wrappers + [
                conversation, senderKeyDistribution, image, contact, location, extendedText, document, audio, video,
                protocolMessage, contactsArray, liveLocation, sticker, deviceSent, messageContextInfo, reaction,
                pollCreation, pollCreationV2, pollCreationV3,
            ])
        }

        public var conversation: String? {
            proto.string(Field.conversation)
        }

        public var extendedText: ExtendedTextMessage? {
            proto.message(Field.extendedText).map(ExtendedTextMessage.init)
        }

        /// The image, video, audio, document or sticker in this message.
        public var media: MediaMessage? {
            for kind in MediaMessage.Kind.allCases {
                if let message = proto.message(kind.field) {
                    return MediaMessage(kind: kind, proto: message)
                }
            }
            return nil
        }

        public var reaction: ReactionMessage? {
            proto.message(Field.reaction).map(ReactionMessage.init)
        }

        public var protocolMessage: ProtocolMessage? {
            proto.message(Field.protocolMessage).map(ProtocolMessage.init)
        }

        public var senderKeyDistribution: SenderKeyDistributionMessage? {
            proto.message(Field.senderKeyDistribution).map(SenderKeyDistributionMessage.init)
        }

        public var deviceSent: DeviceSentMessage? {
            proto.message(Field.deviceSent).map(DeviceSentMessage.init)
        }

        /// waE2E `MessageContextInfo`, kept raw (message secret, and so on).
        public var messageContextInfo: ProtoMessage? {
            proto.message(Field.messageContextInfo)
        }

        public var contact: ContactMessage? {
            proto.message(Field.contact).map(ContactMessage.init)
        }

        /// `contactsArrayMessage`: its display name and how many contacts it holds.
        public var contactsArray: (displayName: String?, count: Int)? {
            proto.message(Field.contactsArray).map { ($0.string(1), $0.repeatedData(2).count) }
        }

        public var location: LocationMessage? {
            proto.message(Field.location).map { LocationMessage(proto: $0, live: false) }
                ?? proto.message(Field.liveLocation).map { LocationMessage(proto: $0, live: true) }
        }

        public var poll: PollCreationMessage? {
            [Field.pollCreation, Field.pollCreationV2, Field.pollCreationV3].lazy.compactMap { proto.message($0) }.first.map(PollCreationMessage.init)
        }

        /// The message inside the first `FutureProofMessage` wrapper (ephemeral, view once, document with
        /// caption, edited), if this message is one.
        public var wrapped: Message? {
            for field in Field.wrappers {
                if let wrapper = proto.message(field) {
                    return wrapper.message(1).map(Message.init)
                }
            }
            return nil
        }

        /// The content with every `FutureProofMessage` wrapper removed. `deviceSentMessage` is left as is, since
        /// its destination matters.
        public var unwrapped: Message {
            var message = self
            while let inner = message.wrapped {
                message = inner
            }
            return message
        }

        /// Field numbers that are set but not modelled here: content the app can only show as unsupported.
        public var unknownFieldNumbers: [Int] {
            var seen = Set<Int>()
            return proto.fields.map(\.number).filter { !Field.modelled.contains($0) && seen.insert($0).inserted }
        }

        // MARK: Building

        /// A text message: plain `conversation`, or `extendedTextMessage` when it replies or mentions.
        public static func text(_ text: String, contextInfo: ContextInfo? = nil) -> Message {
            var message = ProtoMessage()
            if let contextInfo {
                var extended = ProtoMessage()
                extended.set(1, text)
                extended.set(17, contextInfo.proto)
                message.set(Field.extendedText, extended)
            } else {
                message.set(Field.conversation, text)
            }
            return Message(proto: message)
        }

        /// A reaction to `key`; empty text removes the reaction.
        public static func reaction(to key: MessageKey, text: String, senderTimestampMS: Int64) -> Message {
            var reaction = ProtoMessage()
            reaction.set(1, key.proto)
            reaction.set(2, text)
            reaction.set(4, senderTimestampMS)
            var message = ProtoMessage()
            message.set(Field.reaction, reaction)
            return Message(proto: message)
        }

        /// What our other devices get for a message we send: the message and its destination, with the
        /// message's `messageContextInfo` copied alongside (whatsmeow send.go).
        public static func deviceSent(_ message: Message, destinationJID: String) -> Message {
            var sent = ProtoMessage()
            sent.set(1, destinationJID)
            sent.set(2, message.proto)
            var wrapper = ProtoMessage()
            wrapper.set(Field.deviceSent, sent)
            wrapper.set(Field.messageContextInfo, ifPresent: message.messageContextInfo)
            return Message(proto: wrapper)
        }
    }

    /// waE2E `ExtendedTextMessage`: text with a reply, mentions or a link preview.
    struct ExtendedTextMessage: WhatsAppProtoDecodable, Equatable {
        public var text: String?
        public var matchedText: String?
        public var description: String?
        public var title: String?
        public var jpegThumbnail: Data?
        public var contextInfo: ContextInfo?

        public init(proto: ProtoMessage) {
            text = proto.string(1)
            matchedText = proto.string(2)
            description = proto.string(5)
            title = proto.string(6)
            jpegThumbnail = proto.data(16)
            contextInfo = proto.message(17).map(ContextInfo.init)
        }
    }

    /// waE2E `ContextInfo`: what a message replies to and whom it mentions.
    struct ContextInfo: WhatsAppProtoDecodable, WhatsAppProtoEncodable, Equatable {
        /// The quoted message's id.
        public var stanzaID: String?
        /// The quoted message's sender.
        public var participant: String?
        public var quotedMessage: Message?
        /// The quoted message's chat, when it isn't this chat.
        public var remoteJID: String?
        public var mentionedJIDs: [String]

        public init(stanzaID: String? = nil, participant: String? = nil, quotedMessage: Message? = nil, remoteJID: String? = nil, mentionedJIDs: [String] = []) {
            self.stanzaID = stanzaID
            self.participant = participant
            self.quotedMessage = quotedMessage
            self.remoteJID = remoteJID
            self.mentionedJIDs = mentionedJIDs
        }

        public init(proto: ProtoMessage) {
            stanzaID = proto.string(1)
            participant = proto.string(2)
            quotedMessage = proto.message(3).map(Message.init)
            remoteJID = proto.string(4)
            mentionedJIDs = proto.repeatedStrings(15)
        }

        public var proto: ProtoMessage {
            var message = ProtoMessage()
            message.set(1, ifPresent: stanzaID)
            message.set(2, ifPresent: participant)
            message.set(3, ifPresent: quotedMessage?.proto)
            message.set(4, ifPresent: remoteJID)
            for jid in mentionedJIDs {
                message.set(15, jid)
            }
            return message
        }
    }

    /// waE2E `ImageMessage`, `VideoMessage`, `AudioMessage`, `DocumentMessage` and `StickerMessage`: what's
    /// needed to label them and download them later.
    struct MediaMessage: Sendable, Equatable {
        public enum Kind: Sendable, CaseIterable {
            case image, video, audio, document, sticker

            var field: Int {
                switch self {
                case .image: Message.Field.image
                case .video: Message.Field.video
                case .audio: Message.Field.audio
                case .document: Message.Field.document
                case .sticker: Message.Field.sticker
                }
            }

            /// Field numbers per kind: url, mimetype, caption, fileSHA256, fileLength, height, width, mediaKey,
            /// fileEncSHA256, directPath, jpegThumbnail, seconds, ptt, fileName, title.
            var fields: [Int?] {
                switch self {
                case .image: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 16, nil, nil, nil, nil]
                case .video: [1, 2, 7, 3, 4, 9, 10, 6, 11, 13, 16, 5, nil, nil, nil]
                case .audio: [1, 2, nil, 3, 4, nil, nil, 7, 8, 9, nil, 5, 6, nil, nil]
                case .document: [1, 2, 20, 4, 5, nil, nil, 7, 9, 10, 16, nil, nil, 8, 3]
                case .sticker: [1, 5, nil, 2, 9, 6, 7, 4, 3, 8, nil, nil, nil, nil, nil]
                }
            }
        }

        public var kind: Kind
        public var url: String?
        public var mimetype: String?
        public var caption: String?
        public var fileSHA256: Data?
        public var fileLength: UInt64?
        public var height: UInt32?
        public var width: UInt32?
        public var mediaKey: Data?
        public var fileEncSHA256: Data?
        public var directPath: String?
        public var jpegThumbnail: Data?
        public var seconds: UInt32?
        public var ptt: Bool?
        public var fileName: String?
        public var title: String?
        /// Video `gifPlayback` or sticker `isAnimated`.
        public var isAnimated: Bool?
        /// Audio `waveform`: 64 levels, one byte each.
        public var waveform: Data?
        public var contextInfo: ContextInfo?

        init(kind: Kind, proto: ProtoMessage) {
            self.kind = kind
            let f = kind.fields
            url = f[0].flatMap(proto.string)
            mimetype = f[1].flatMap(proto.string)
            caption = f[2].flatMap(proto.string)
            fileSHA256 = f[3].flatMap(proto.data)
            fileLength = f[4].flatMap(proto.uint64)
            height = f[5].flatMap(proto.uint32)
            width = f[6].flatMap(proto.uint32)
            mediaKey = f[7].flatMap(proto.data)
            fileEncSHA256 = f[8].flatMap(proto.data)
            directPath = f[9].flatMap(proto.string)
            jpegThumbnail = f[10].flatMap(proto.data)
            seconds = f[11].flatMap(proto.uint32)
            ptt = f[12].flatMap(proto.bool)
            fileName = f[13].flatMap(proto.string)
            title = f[14].flatMap(proto.string)
            isAnimated = switch kind {
            case .video: proto.bool(8)
            case .sticker: proto.bool(13)
            default: nil
            }
            waveform = kind == .audio ? proto.data(19) : nil
            contextInfo = proto.message(17).map(ContextInfo.init)
        }
    }

    /// waE2E `ReactionMessage`.
    struct ReactionMessage: WhatsAppProtoDecodable, Equatable {
        public var key: MessageKey?
        /// The emoji; empty when the reaction was removed.
        public var text: String?
        public var senderTimestampMS: Int64?

        public init(proto: ProtoMessage) {
            key = proto.message(1).map(MessageKey.init)
            text = proto.string(2)
            senderTimestampMS = proto.int64(4)
        }
    }

    /// waE2E `ProtocolMessage`: revokes, edits, history sync, app state keys and LID mappings.
    struct ProtocolMessage: WhatsAppProtoDecodable, Equatable {
        /// `ProtocolMessage.Type` values the app handles; others stay in `type`.
        public enum Kind: UInt64, Sendable {
            case revoke = 0
            case ephemeralSetting = 3
            case historySyncNotification = 5
            case appStateSyncKeyShare = 6
            case messageEdit = 14
            case lidMigrationMappingSync = 22
        }

        public var key: MessageKey?
        public var type: UInt64?
        public var historySyncNotification: HistorySyncNotification?
        public var appStateSyncKeyShare: AppStateSyncKeyShare?
        public var editedMessage: Message?
        public var timestampMS: Int64?
        /// `lidMigrationMappingSyncMessage.encodedMappingPayload`, a `LIDMigrationMappingSyncPayload`.
        public var lidMigrationMappingPayload: Data?
        /// Messages the phone resent for an unavailable-message request: each a serialized `WebMessageInfo`
        /// (`peerDataOperationRequestResponseMessage.peerDataOperationResult[].placeholderMessageResendResponse`).
        public var resentMessages: [Data]

        public var kind: Kind? {
            type.flatMap(Kind.init)
        }

        public init(proto: ProtoMessage) {
            key = proto.message(1).map(MessageKey.init)
            type = proto.uint64(2)
            historySyncNotification = proto.message(6).map(HistorySyncNotification.init)
            appStateSyncKeyShare = proto.message(7).map(AppStateSyncKeyShare.init)
            editedMessage = proto.message(14).map(Message.init)
            timestampMS = proto.int64(15)
            lidMigrationMappingPayload = proto.message(23)?.data(1)
            resentMessages = (proto.message(17)?.messages(3) ?? []).compactMap { $0.message(4)?.data(1) }
        }
    }

    /// waE2E `SenderKeyDistributionMessage`: a group sender key, sent alongside a group message.
    struct SenderKeyDistributionMessage: WhatsAppProtoDecodable, Equatable {
        public var groupID: String?
        public var axolotlSenderKeyDistributionMessage: Data?

        public init(proto: ProtoMessage) {
            groupID = proto.string(1)
            axolotlSenderKeyDistributionMessage = proto.data(2)
        }
    }

    /// waE2E `DeviceSentMessage`: a message our own other device sent, with the chat it went to.
    struct DeviceSentMessage: WhatsAppProtoDecodable, Equatable {
        public var destinationJID: String?
        public var message: Message?

        public init(proto: ProtoMessage) {
            destinationJID = proto.string(1)
            message = proto.message(2).map(Message.init)
        }
    }

    /// waE2E `ContactMessage`.
    struct ContactMessage: WhatsAppProtoDecodable, Equatable {
        public var displayName: String?
        public var vcard: String?

        public init(proto: ProtoMessage) {
            displayName = proto.string(1)
            vcard = proto.string(16)
        }
    }

    /// waE2E `LocationMessage` or `LiveLocationMessage`.
    struct LocationMessage: Sendable, Equatable {
        public var isLive: Bool
        public var latitude: Double?
        public var longitude: Double?
        public var name: String?
        public var address: String?
        /// Live locations' caption.
        public var caption: String?

        init(proto: ProtoMessage, live: Bool) {
            isLive = live
            latitude = proto.uint64(1).map { Double(bitPattern: $0) }
            longitude = proto.uint64(2).map { Double(bitPattern: $0) }
            if live {
                caption = proto.string(6)
            } else {
                name = proto.string(3)
                address = proto.string(4)
            }
        }
    }

    /// waE2E `PollCreationMessage` (any version).
    struct PollCreationMessage: WhatsAppProtoDecodable, Equatable {
        public var name: String?
        public var options: [String]

        public init(proto: ProtoMessage) {
            name = proto.string(2)
            options = proto.messages(3).compactMap { $0.string(1) }
        }
    }

    /// waE2E `HistorySyncNotification`: where to download a history sync blob, or the blob itself inline.
    struct HistorySyncNotification: WhatsAppProtoDecodable, Equatable {
        public var fileSHA256: Data?
        public var fileLength: UInt64?
        public var mediaKey: Data?
        public var fileEncSHA256: Data?
        public var directPath: String?
        public var syncType: UInt64?
        public var chunkOrder: UInt32?
        public var originalMessageID: String?
        public var progress: UInt32?
        /// The zlib-compressed `HistorySync`, when it came inline.
        public var initialHistBootstrapInlinePayload: Data?

        public init(proto: ProtoMessage) {
            fileSHA256 = proto.data(1)
            fileLength = proto.uint64(2)
            mediaKey = proto.data(3)
            fileEncSHA256 = proto.data(4)
            directPath = proto.string(5)
            syncType = proto.uint64(6)
            chunkOrder = proto.uint32(7)
            originalMessageID = proto.string(8)
            progress = proto.uint32(9)
            initialHistBootstrapInlinePayload = proto.data(11)
        }
    }

    /// waE2E `AppStateSyncKeyShare`.
    struct AppStateSyncKeyShare: WhatsAppProtoDecodable, Equatable {
        public var keys: [AppStateSyncKey]

        public init(proto: ProtoMessage) {
            keys = proto.messages(1).map(AppStateSyncKey.init)
        }
    }

    /// waE2E `AppStateSyncKey`: `keyID.keyID` and `keyData` (key, fingerprint, timestamp).
    struct AppStateSyncKey: WhatsAppProtoDecodable, Equatable {
        public var keyID: Data?
        public var keyData: Data?
        /// The serialized `AppStateSyncKeyFingerprint`, stored as is.
        public var fingerprint: Data?
        public var timestamp: Int64?

        public init(proto: ProtoMessage) {
            keyID = proto.message(1)?.data(1)
            let data = proto.message(2)
            keyData = data?.data(1)
            fingerprint = data?.data(2)
            timestamp = data?.int64(3)
        }
    }

    /// waLidMigrationSyncPayload `LIDMigrationMappingSyncPayload`: phone numbers and their LIDs (user parts).
    struct LIDMigrationMappingSyncPayload: WhatsAppProtoDecodable, Equatable {
        public struct Mapping: Sendable, Equatable {
            public var pn: UInt64
            public var assignedLID: UInt64
        }

        public var mappings: [Mapping]

        public init(proto: ProtoMessage) {
            mappings = proto.messages(1).map { Mapping(pn: $0.uint64(1) ?? 0, assignedLID: $0.uint64(2) ?? 0) }
        }
    }
}

// MARK: - waWeb and waHistorySync

public extension WhatsAppProto {
    /// waWeb `WebMessageInfo`: a stored message, as history sync delivers it.
    struct WebMessageInfo: WhatsAppProtoDecodable, Equatable {
        public var key: MessageKey?
        public var message: Message?
        public var messageTimestamp: UInt64
        /// `WebMessageInfo.Status`: 0 error, 1 pending, 2 server ack, 3 delivered, 4 read, 5 played.
        public var status: UInt64?
        public var participant: String?
        public var pushName: String?
        /// `WebMessageInfo.StubType` for system messages (joins, subject changes, and so on).
        public var messageStubType: UInt64?
        public var messageStubParameters: [String]
        public var reactions: [Reaction]

        public init(proto: ProtoMessage) {
            key = proto.message(1).map(MessageKey.init)
            message = proto.message(2).map(Message.init)
            messageTimestamp = proto.uint64(3) ?? 0
            status = proto.uint64(4)
            participant = proto.string(5)
            pushName = proto.string(19)
            messageStubType = proto.uint64(24)
            messageStubParameters = proto.repeatedStrings(26)
            reactions = proto.messages(41).map(Reaction.init)
        }
    }

    /// waWeb `Reaction`.
    struct Reaction: WhatsAppProtoDecodable, Equatable {
        public var key: MessageKey?
        public var text: String?
        public var senderTimestampMS: Int64?
        public var unread: Bool

        public init(proto: ProtoMessage) {
            key = proto.message(1).map(MessageKey.init)
            text = proto.string(2)
            senderTimestampMS = proto.int64(4)
            unread = proto.bool(5) ?? false
        }
    }

    /// waHistorySync `HistorySync`: one decompressed history sync chunk.
    struct HistorySync: WhatsAppProtoDecodable, Equatable {
        /// `HistorySync.HistorySyncType`.
        public enum SyncType: UInt64, Sendable {
            case initialBootstrap = 0
            case initialStatusV3 = 1
            case full = 2
            case recent = 3
            case pushName = 4
            case nonBlockingData = 5
            case onDemand = 6
        }

        /// `HistorySync.Pushname`.
        public struct Pushname: Sendable, Equatable {
            public var id: String
            public var pushname: String
        }

        /// `PhoneNumberToLIDMapping`.
        public struct LIDMapping: Sendable, Equatable {
            public var pnJID: String
            public var lidJID: String
        }

        public var syncType: SyncType?
        public var conversations: [Conversation]
        public var chunkOrder: UInt32
        public var progress: UInt32
        public var pushnames: [Pushname]
        public var phoneNumberToLIDMappings: [LIDMapping]

        public init(proto: ProtoMessage) {
            syncType = proto.uint64(1).flatMap(SyncType.init)
            conversations = proto.messages(2).map(Conversation.init)
            chunkOrder = proto.uint32(5) ?? 0
            progress = proto.uint32(6) ?? 0
            pushnames = proto.messages(7).map { Pushname(id: $0.string(1) ?? "", pushname: $0.string(2) ?? "") }
            phoneNumberToLIDMappings = proto.messages(15).map { LIDMapping(pnJID: $0.string(1) ?? "", lidJID: $0.string(2) ?? "") }
        }
    }

    /// waHistorySync `Conversation`.
    struct Conversation: WhatsAppProtoDecodable, Equatable {
        /// `GroupParticipant`; rank 0 regular, 1 admin, 2 superadmin.
        public struct Participant: Sendable, Equatable {
            public var userJID: String
            public var rank: UInt64
        }

        public var id: String
        /// `messages[].message` (each `HistorySyncMsg`'s `WebMessageInfo`).
        public var messages: [WebMessageInfo]
        public var lastMsgTimestamp: UInt64
        public var unreadCount: UInt32
        public var readOnly: Bool
        public var ephemeralExpiration: UInt32
        public var conversationTimestamp: UInt64
        public var name: String?
        public var archived: Bool
        public var markedAsUnread: Bool
        public var participants: [Participant]
        /// When the chat was pinned (seconds); 0 when it isn't.
        public var pinned: UInt32
        public var muteEndTime: UInt64
        public var displayName: String?
        public var pnJID: String?
        public var lidJID: String?
        public var username: String?
        /// The contact's privacy token for us, its time and when we last issued ours to them.
        public var tcToken: Data?
        public var tcTokenTimestamp: UInt64
        public var tcTokenSenderTimestamp: UInt64

        public init(proto: ProtoMessage) {
            id = proto.string(1) ?? ""
            tcToken = proto.data(21)
            tcTokenTimestamp = proto.uint64(22) ?? 0
            tcTokenSenderTimestamp = proto.uint64(28) ?? 0
            messages = proto.messages(2).compactMap { $0.message(1).map(WebMessageInfo.init) }
            lastMsgTimestamp = proto.uint64(5) ?? 0
            unreadCount = proto.uint32(6) ?? 0
            readOnly = proto.bool(7) ?? false
            ephemeralExpiration = proto.uint32(9) ?? 0
            conversationTimestamp = proto.uint64(12) ?? 0
            name = proto.string(13)
            archived = proto.bool(16) ?? false
            markedAsUnread = proto.bool(19) ?? false
            participants = proto.messages(20).map { Participant(userJID: $0.string(1) ?? "", rank: $0.uint64(2) ?? 0) }
            pinned = proto.uint32(24) ?? 0
            muteEndTime = proto.uint64(25) ?? 0
            displayName = proto.string(38)
            pnJID = proto.string(39)
            lidJID = proto.string(42)
            username = proto.string(43)
        }
    }
}

// MARK: - waServerSync (app state)

public extension WhatsAppProto {
    /// waServerSync `ExternalBlobReference`: an app state blob on the media servers.
    struct ExternalBlobReference: WhatsAppProtoDecodable, Equatable {
        public var mediaKey: Data?
        public var directPath: String?
        public var handle: String?
        public var fileSizeBytes: UInt64?
        public var fileSHA256: Data?
        public var fileEncSHA256: Data?

        public init(proto: ProtoMessage) {
            mediaKey = proto.data(1)
            directPath = proto.string(2)
            handle = proto.string(3)
            fileSizeBytes = proto.uint64(4)
            fileSHA256 = proto.data(5)
            fileEncSHA256 = proto.data(6)
        }
    }

    /// waServerSync `SyncdRecord`: `index.blob`, `value.blob` and `keyID.ID`.
    struct SyncdRecord: WhatsAppProtoDecodable, Equatable {
        public var index: Data
        public var value: Data
        public var keyID: Data

        public init(proto: ProtoMessage) {
            index = proto.message(1)?.data(1) ?? Data()
            value = proto.message(2)?.data(1) ?? Data()
            keyID = proto.message(3)?.data(1) ?? Data()
        }
    }

    /// waServerSync `SyncdMutation`.
    struct SyncdMutation: WhatsAppProtoDecodable, Equatable {
        /// `SyncdMutation.SyncdOperation`.
        public enum Operation: UInt64, Sendable {
            case set = 0
            case remove = 1
        }

        public var operation: Operation
        public var record: SyncdRecord

        public init(proto: ProtoMessage) {
            operation = proto.uint64(1).flatMap(Operation.init) ?? .set
            record = SyncdRecord(proto: proto.message(2) ?? ProtoMessage())
        }
    }

    /// waServerSync `SyncdMutations`: a patch's mutations when they're stored externally.
    struct SyncdMutations: WhatsAppProtoDecodable, Equatable {
        public var mutations: [SyncdMutation]

        public init(proto: ProtoMessage) {
            mutations = proto.messages(1).map(SyncdMutation.init)
        }
    }

    /// waServerSync `SyncdSnapshot`.
    struct SyncdSnapshot: WhatsAppProtoDecodable, Equatable {
        public var version: UInt64
        public var records: [SyncdRecord]
        public var mac: Data
        public var keyID: Data

        public init(proto: ProtoMessage) {
            version = proto.message(1)?.uint64(1) ?? 0
            records = proto.messages(2).map(SyncdRecord.init)
            mac = proto.data(3) ?? Data()
            keyID = proto.message(4)?.data(1) ?? Data()
        }
    }

    /// waServerSync `SyncdPatch`. When `externalMutations` is set, replace `mutations` with the downloaded
    /// `SyncdMutations`.
    struct SyncdPatch: WhatsAppProtoDecodable, Equatable {
        public var version: UInt64
        public var mutations: [SyncdMutation]
        public var externalMutations: ExternalBlobReference?
        public var snapshotMAC: Data
        public var patchMAC: Data
        public var keyID: Data
        public var deviceIndex: UInt32?

        public init(proto: ProtoMessage) {
            version = proto.message(1)?.uint64(1) ?? 0
            mutations = proto.messages(2).map(SyncdMutation.init)
            externalMutations = proto.message(3).map(ExternalBlobReference.init)
            snapshotMAC = proto.data(4) ?? Data()
            patchMAC = proto.data(5) ?? Data()
            keyID = proto.message(6)?.data(1) ?? Data()
            deviceIndex = proto.uint32(8)
        }
    }
}

// MARK: - waSyncAction

public extension WhatsAppProto {
    /// waSyncAction `SyncActionData`: a decrypted app state mutation.
    struct SyncActionData: WhatsAppProtoDecodable, Equatable {
        /// JSON array, e.g. `["mute","123@lid"]`.
        public var index: Data
        public var value: SyncActionValue?
        public var version: Int32

        public init(proto: ProtoMessage) {
            index = proto.data(1) ?? Data()
            value = proto.message(2).map(SyncActionValue.init)
            version = proto.int32(4) ?? 0
        }
    }

    /// waSyncAction `SyncActionValue`, only the actions that shape the Chats list.
    struct SyncActionValue: WhatsAppProtoDecodable, Equatable {
        /// `ContactAction`.
        public struct ContactAction: Sendable, Equatable {
            public var fullName: String?
            public var firstName: String?
            public var lidJID: String?
            public var pnJID: String?
            public var username: String?
        }

        /// `MuteAction`; `muteEndTimestamp` is -1 for "always".
        public struct MuteAction: Sendable, Equatable {
            public var muted: Bool
            public var muteEndTimestamp: Int64?
        }

        public var timestamp: Int64?
        public var contactAction: ContactAction?
        public var muteAction: MuteAction?
        /// `pinAction.pinned`.
        public var pinned: Bool?
        /// `archiveChatAction.archived`.
        public var archived: Bool?
        /// `markChatAsReadAction.read`.
        public var read: Bool?
        /// `lockChatAction.locked`: WhatsApp hides locked chats behind a passcode.
        public var locked: Bool?
        /// Whether `clearChatAction` is set.
        public var clearsChat: Bool
        /// Whether `deleteChatAction` is set.
        public var deletesChat: Bool

        public init(proto: ProtoMessage) {
            timestamp = proto.int64(1)
            contactAction = proto.message(3).map {
                ContactAction(fullName: $0.string(1), firstName: $0.string(2), lidJID: $0.string(3), pnJID: $0.string(5), username: $0.string(6))
            }
            muteAction = proto.message(4).map { MuteAction(muted: $0.bool(1) ?? false, muteEndTimestamp: $0.int64(2)) }
            pinned = proto.message(5).map { $0.bool(1) ?? false }
            archived = proto.message(17).map { $0.bool(1) ?? false }
            read = proto.message(20).map { $0.bool(1) ?? false }
            locked = proto.message(50).map { $0.bool(1) ?? false }
            clearsChat = proto.has(21)
            deletesChat = proto.has(22)
        }
    }
}
