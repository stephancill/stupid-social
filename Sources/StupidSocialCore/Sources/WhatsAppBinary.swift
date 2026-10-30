import Foundation

/// A WhatsApp address (whatsmeow types/jid.go): `user[.agent][:device]@server`, or a bare server.
public struct WhatsAppJID: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Server {
        public static let user = "s.whatsapp.net"
        public static let lid = "lid"
        public static let group = "g.us"
        public static let broadcast = "broadcast"
        public static let newsletter = "newsletter"
        public static let hosted = "hosted"
        public static let hostedLID = "hosted.lid"
    }

    /// The server itself, `s.whatsapp.net`, which iqs and receipts to the server address.
    public static let server = WhatsAppJID(user: "", server: Server.user)

    public var user: String
    public var server: String
    public var device: Int
    public var agent: Int

    public init(user: String, server: String, device: Int = 0, agent: Int = 0) {
        self.user = user
        self.server = server
        self.device = device
        self.agent = agent
    }

    /// Parses like the probe's `JID.parse`; text without `@` is a bare server.
    public init?(string text: String) {
        guard let at = text.firstIndex(of: "@") else {
            self.init(user: "", server: text)
            return
        }
        var user = String(text[..<at])
        let server = String(text[text.index(after: at)...])
        var device = 0
        var agent = 0
        if let dot = user.firstIndex(of: ".") {
            let ad = user[user.index(after: dot)...]
            let agentText = ad.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let deviceText = ad.contains(":") ? ad[ad.index(after: ad.firstIndex(of: ":")!)...] : ""
            guard let parsedAgent = Int(agentText) else { return nil }
            agent = parsedAgent
            if !deviceText.isEmpty {
                guard let parsedDevice = Int(deviceText) else { return nil }
                device = parsedDevice
            }
            user = String(user[..<dot])
        } else if let colon = user.firstIndex(of: ":") {
            guard let parsedDevice = Int(user[user.index(after: colon)...]) else { return nil }
            device = parsedDevice
            user = String(user[..<colon])
        }
        self.init(user: user, server: server, device: device, agent: agent)
    }

    public var description: String {
        if server.isEmpty { return "" }
        if user.isEmpty { return server }
        if agent != 0 { return "\(user).\(agent):\(device)@\(server)" }
        if device != 0 { return "\(user):\(device)@\(server)" }
        return "\(user)@\(server)"
    }

    /// The user without device or agent.
    public var nonAD: WhatsAppJID {
        WhatsAppJID(user: user, server: server)
    }

    /// libsignal's address `name.device`, with the domain for non-default servers (whatsmeow SignalAddressUser).
    public var signalAddress: String {
        let name = switch server {
        case Server.lid: "\(user)_1"
        case Server.hosted: "\(user)_128"
        case Server.hostedLID: "\(user)_129"
        default: agent != 0 ? "\(user)_\(agent)" : user
        }
        return "\(name).\(device)"
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let jid = WhatsAppJID(string: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid JID"))
        }
        self = jid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum WhatsAppAttribute: Sendable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    case string(String)
    case jid(WhatsAppJID)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public var description: String {
        switch self {
        case let .string(text): text
        case let .jid(jid): jid.description
        }
    }
}

/// A binary XML stanza (whatsmeow binary/node.go). Attributes keep their insertion order so encodings are
/// deterministic; the server doesn't care about the order.
public struct WhatsAppNode: Sendable, Equatable, CustomStringConvertible {
    public enum Content: Sendable, Equatable {
        case none
        case bytes(Data)
        /// Decoded token, packed or raw string content (the decoder reads binary content as bytes).
        case string(String)
        case jid(WhatsAppJID)
        case nodes([WhatsAppNode])
    }

    public struct Attribute: Sendable, Equatable {
        public var key: String
        public var value: WhatsAppAttribute
    }

    public var tag: String
    public var attributes: [Attribute]
    public var content: Content

    public init(_ tag: String, _ attributes: KeyValuePairs<String, WhatsAppAttribute> = [:], content: Content = .none) {
        self.tag = tag
        self.attributes = attributes.map { Attribute(key: $0.key, value: $0.value) }
        self.content = content
    }

    public init(_ tag: String, _ attributes: KeyValuePairs<String, WhatsAppAttribute> = [:], children: [WhatsAppNode]) {
        self.init(tag, attributes, content: .nodes(children))
    }

    public init(_ tag: String, _ attributes: KeyValuePairs<String, WhatsAppAttribute> = [:], bytes: Data) {
        self.init(tag, attributes, content: .bytes(bytes))
    }

    public subscript(key: String) -> WhatsAppAttribute? {
        get { attributes.last { $0.key == key }?.value }
        set {
            if let index = attributes.firstIndex(where: { $0.key == key }) {
                if let newValue { attributes[index].value = newValue } else { attributes.remove(at: index) }
            } else if let newValue {
                attributes.append(Attribute(key: key, value: newValue))
            }
        }
    }

    /// The attribute as text (a JID as its string), or nil when absent.
    public func attr(_ key: String) -> String? {
        self[key]?.description
    }

    /// The attribute when it was encoded as a JID.
    public func jid(_ key: String) -> WhatsAppJID? {
        if case let .jid(jid) = self[key] { jid } else { nil }
    }

    public var children: [WhatsAppNode] {
        if case let .nodes(nodes) = content { nodes } else { [] }
    }

    /// The first child with the first tag, then its first child with the next tag, and so on.
    public func child(_ tags: String...) -> WhatsAppNode? {
        var node: WhatsAppNode? = self
        for tag in tags {
            node = node?.children.first { $0.tag == tag }
        }
        return node
    }

    /// Binary content, or string content as UTF-8; empty otherwise.
    public var bytes: Data {
        switch content {
        case let .bytes(data): data
        case let .string(text): Data(text.utf8)
        default: Data()
        }
    }

    /// XML-ish rendering; binary and string contents show as their length so payloads never print.
    public var description: String {
        describe(depth: 0)
    }

    private func describe(depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let attrs = attributes.map { " \($0.key)=\"\($0.value)\"" }.joined()
        switch content {
        case .none:
            return "\(pad)<\(tag)\(attrs)/>"
        case let .bytes(data):
            return "\(pad)<\(tag)\(attrs)>[\(data.count) bytes]</\(tag)>"
        case let .string(text):
            return "\(pad)<\(tag)\(attrs)>[\(text.count) chars]</\(tag)>"
        case let .jid(jid):
            return "\(pad)<\(tag)\(attrs)>\(jid)</\(tag)>"
        case let .nodes(nodes):
            let inner = nodes.map { $0.describe(depth: depth + 1) }.joined(separator: "\n")
            return "\(pad)<\(tag)\(attrs)>\n\(inner)\n\(pad)</\(tag)>"
        }
    }

    // MARK: Encoding and decoding

    /// The stanza with its leading flags byte (0: uncompressed), ready for the Noise transport.
    public func encoded() -> Data {
        var encoder = WhatsAppNodeEncoder()
        encoder.node(self)
        return Data(encoder.bytes)
    }

    /// Decodes a decrypted frame: a flags byte (2: zlib-compressed), then one stanza.
    public static func decode(frame: Data) throws -> WhatsAppNode {
        guard let flags = frame.first else { throw WhatsAppBinaryError.truncated }
        var body = Data(frame.dropFirst())
        if flags & 2 != 0 {
            body = try WhatsAppZlib.decompress(body)
        }
        var decoder = WhatsAppNodeDecoder(bytes: [UInt8](body))
        let node = try decoder.node()
        guard decoder.index == decoder.bytes.count else {
            throw WhatsAppBinaryError.leftoverBytes(decoder.bytes.count - decoder.index)
        }
        return node
    }
}

public enum WhatsAppBinaryError: Error, Equatable {
    case truncated
    case invalidListTag(UInt8)
    case invalidToken(UInt8)
    case invalidNibble(UInt8)
    case invalidNode
    case invalidJID
    case leftoverBytes(Int)
    case zlib
}

/// zlib streams (RFC 1950), which WhatsApp uses for compressed frames and history sync blobs.
public enum WhatsAppZlib {
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // CMF/FLG header: deflate, no preset dictionary, header checksum; then the Adler-32 trailer.
        guard bytes.count >= 6, bytes[0] & 0x0F == 8, bytes[1] & 0x20 == 0,
              (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0
        else { throw WhatsAppBinaryError.zlib }
        // Apple's .zlib algorithm is raw deflate (RFC 1951), so the header and trailer are handled here.
        let deflated = Data(bytes[2 ..< bytes.count - 4])
        let output: Data
        do {
            output = try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw WhatsAppBinaryError.zlib
        }
        let expected = bytes[(bytes.count - 4)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard adler32(output) == expected else { throw WhatsAppBinaryError.zlib }
        return output
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            while index < buffer.count {
                // 5552 bytes is the most that can be summed before the 32-bit sums could overflow.
                let end = min(index + 5552, buffer.count)
                for byte in buffer[index ..< end] {
                    a += UInt32(byte)
                    b += a
                }
                a %= 65521
                b %= 65521
                index = end
            }
        }
        return b << 16 | a
    }
}

// MARK: - Tokens

/// The token dictionaries from WhatsAppTokens.json (scripts/whatsapp-tokens.py, whatsmeow binary/token).
struct WhatsAppTokens {
    static let shared = WhatsAppTokens()

    let dictVersion: UInt8
    let single: [String]
    let double: [[String]]
    let singleIndex: [String: UInt8]
    let doubleIndex: [String: (dictionary: UInt8, index: UInt8)]

    private init() {
        struct File: Decodable {
            let dictVersion: UInt8
            let single: [String]
            let double: [[String]]
        }
        guard let url = Bundle.module.url(forResource: "WhatsAppTokens", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { fatalError("WhatsAppTokens.json is missing from the bundle") }
        dictVersion = file.dictVersion
        single = file.single
        double = file.double
        var singleIndex: [String: UInt8] = [:]
        for (index, token) in file.single.enumerated() where !token.isEmpty {
            singleIndex[token] = UInt8(index)
        }
        var doubleIndex: [String: (UInt8, UInt8)] = [:]
        for (dictionary, tokens) in file.double.enumerated() {
            for (index, token) in tokens.enumerated() {
                doubleIndex[token] = (UInt8(dictionary), UInt8(index))
            }
        }
        self.singleIndex = singleIndex
        self.doubleIndex = doubleIndex
    }
}

private enum Tag {
    static let listEmpty: UInt8 = 0
    static let dictionary0: UInt8 = 236
    static let interopJID: UInt8 = 245
    static let fbJID: UInt8 = 246
    static let adJID: UInt8 = 247
    static let list8: UInt8 = 248
    static let list16: UInt8 = 249
    static let jidPair: UInt8 = 250
    static let hex8: UInt8 = 251
    static let binary8: UInt8 = 252
    static let binary20: UInt8 = 253
    static let binary32: UInt8 = 254
    static let nibble8: UInt8 = 255
    static let packedMax = 127
}

/// Domain types in AD JIDs (whatsmeow types/jid.go).
private let domainServers: [UInt8: String] = [0: WhatsAppJID.Server.user, 1: WhatsAppJID.Server.lid, 128: WhatsAppJID.Server.hosted, 129: WhatsAppJID.Server.hostedLID]

// MARK: - Encoder

private struct WhatsAppNodeEncoder {
    var bytes: [UInt8] = [0]
    let tokens = WhatsAppTokens.shared

    mutating func byteLength(_ length: Int) {
        if length < 256 {
            bytes += [Tag.binary8, UInt8(length)]
        } else if length < 1 << 20 {
            bytes += [Tag.binary20, UInt8((length >> 16) & 0x0F), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        } else {
            bytes += [Tag.binary32, UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    mutating func listStart(_ size: Int) {
        if size == 0 {
            bytes.append(Tag.listEmpty)
        } else if size < 256 {
            bytes += [Tag.list8, UInt8(size)]
        } else {
            bytes += [Tag.list16, UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
        }
    }

    mutating func node(_ node: WhatsAppNode) {
        let attributes = node.attributes.filter { $0.value != .string("") }
        let hasContent = if case .none = node.content { false } else { true }
        listStart(2 * attributes.count + 1 + (hasContent ? 1 : 0))
        string(node.tag)
        for attribute in attributes {
            string(attribute.key)
            switch attribute.value {
            case let .string(text): string(text)
            case let .jid(value): jid(value)
            }
        }
        switch node.content {
        case .none:
            break
        case let .bytes(data):
            byteLength(data.count)
            bytes += data
        case let .string(text):
            string(text)
        case let .jid(value):
            jid(value)
        case let .nodes(children):
            listStart(children.count)
            for child in children {
                self.node(child)
            }
        }
    }

    mutating func string(_ text: String) {
        if let index = tokens.singleIndex[text] {
            bytes.append(index)
        } else if let token = tokens.doubleIndex[text] {
            bytes += [Tag.dictionary0 + token.dictionary, token.index]
        } else if Self.packable(text, nibble: true) {
            packed(text, kind: Tag.nibble8)
        } else if Self.packable(text, nibble: false) {
            packed(text, kind: Tag.hex8)
        } else {
            let raw = Array(text.utf8)
            byteLength(raw.count)
            bytes += raw
        }
    }

    static func packable(_ text: String, nibble: Bool) -> Bool {
        let utf8 = text.utf8
        guard !utf8.isEmpty, utf8.count <= Tag.packedMax else { return false }
        return utf8.allSatisfy { char in
            (char >= 0x30 && char <= 0x39) || (nibble ? char == 0x2D || char == 0x2E : char >= 0x41 && char <= 0x46)
        }
    }

    mutating func packed(_ text: String, kind: UInt8) {
        func pack(_ char: UInt8) -> UInt8 {
            switch char {
            case 0: 15
            case 0x2D: 10
            case 0x2E: 11
            case 0x30 ... 0x39: char - 0x30
            default: 10 + char - 0x41
            }
        }
        var chars = Array(text.utf8)
        let odd = chars.count % 2 == 1
        bytes += [kind, UInt8((chars.count + 1) / 2) | (odd ? 128 : 0)]
        if odd { chars.append(0) }
        for index in stride(from: 0, to: chars.count, by: 2) {
            bytes.append(pack(chars[index]) << 4 | pack(chars[index + 1]))
        }
    }

    mutating func jid(_ jid: WhatsAppJID) {
        let server = jid.server
        let isAD = ((server == WhatsAppJID.Server.user || server == WhatsAppJID.Server.lid) && jid.device > 0)
            || server == WhatsAppJID.Server.hosted || server == WhatsAppJID.Server.hostedLID
        if isAD {
            let domain: Int = switch server {
            case WhatsAppJID.Server.lid: 1
            case WhatsAppJID.Server.hosted: 128
            case WhatsAppJID.Server.hostedLID: 129
            default: jid.agent
            }
            bytes += [Tag.adJID, UInt8(truncatingIfNeeded: domain), UInt8(truncatingIfNeeded: jid.device)]
            string(jid.user)
        } else {
            bytes.append(Tag.jidPair)
            if jid.user.isEmpty {
                bytes.append(Tag.listEmpty)
            } else {
                string(jid.user)
            }
            string(server)
        }
    }
}

// MARK: - Decoder

private struct WhatsAppNodeDecoder {
    let bytes: [UInt8]
    var index = 0
    let tokens = WhatsAppTokens.shared

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, bytes.count - index >= count else { throw WhatsAppBinaryError.truncated }
        defer { index += count }
        return bytes[index ..< index + count]
    }

    mutating func byte() throws -> UInt8 {
        try take(1).first!
    }

    mutating func int(_ count: Int) throws -> Int {
        try take(count).reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func listSize(_ tag: UInt8) throws -> Int {
        switch tag {
        case Tag.listEmpty: 0
        case Tag.list8: try int(1)
        case Tag.list16: try int(2)
        default: throw WhatsAppBinaryError.invalidListTag(tag)
        }
    }

    enum Value {
        case none
        case nodes([WhatsAppNode])
        case bytes(Data)
        case string(String)
        case jid(WhatsAppJID)
    }

    mutating func read(asString: Bool) throws -> Value {
        let tag = try byte()
        switch tag {
        case Tag.listEmpty:
            return .none
        case Tag.list8, Tag.list16:
            let size = try listSize(tag)
            var nodes: [WhatsAppNode] = []
            for _ in 0 ..< size {
                try nodes.append(node())
            }
            return .nodes(nodes)
        case Tag.binary8, Tag.binary20, Tag.binary32:
            let size: Int
            switch tag {
            case Tag.binary8:
                size = try int(1)
            case Tag.binary20:
                let raw = try take(3)
                size = Int(raw[raw.startIndex] & 0x0F) << 16 | Int(raw[raw.startIndex + 1]) << 8 | Int(raw[raw.startIndex + 2])
            default:
                size = try int(4)
            }
            let data = try Data(take(size))
            guard asString else { return .bytes(data) }
            guard let text = String(data: data, encoding: .utf8) else { throw WhatsAppBinaryError.invalidNode }
            return .string(text)
        case Tag.dictionary0 ... Tag.dictionary0 + 3:
            let dictionary = tokens.double[Int(tag - Tag.dictionary0)]
            let index = try int(1)
            guard index < dictionary.count else { throw WhatsAppBinaryError.invalidToken(tag) }
            return .string(dictionary[index])
        case Tag.jidPair:
            let user = try readString()
            guard let server = try readString() else { throw WhatsAppBinaryError.invalidJID }
            return .jid(WhatsAppJID(user: user ?? "", server: server))
        case Tag.adJID:
            let domain = try byte()
            let device = try int(1)
            let user = try readString() ?? ""
            if domain != 0, let server = domainServers[domain] {
                return .jid(WhatsAppJID(user: user, server: server, device: device))
            }
            return .jid(WhatsAppJID(user: user, server: WhatsAppJID.Server.user, device: device, agent: Int(domain)))
        case Tag.fbJID:
            let user = try readString() ?? ""
            let device = try int(2)
            let server = try readString() ?? ""
            return .jid(WhatsAppJID(user: user, server: server, device: device))
        case Tag.interopJID:
            let user = try readString() ?? ""
            let device = try int(2)
            _ = try int(2)
            let server = try readString() ?? ""
            return .jid(WhatsAppJID(user: user, server: server, device: device))
        case Tag.nibble8, Tag.hex8:
            return try .string(packed(tag))
        default:
            guard tag >= 1, Int(tag) < tokens.single.count else { throw WhatsAppBinaryError.invalidToken(tag) }
            return .string(tokens.single[Int(tag)])
        }
    }

    /// A value read as a string; JIDs (as in attributes) become their text.
    mutating func readString() throws -> String? {
        switch try read(asString: true) {
        case .none: nil
        case let .string(text): text
        case let .jid(jid): jid.description
        case .bytes, .nodes: throw WhatsAppBinaryError.invalidNode
        }
    }

    mutating func packed(_ tag: UInt8) throws -> String {
        let start = try byte()
        var chars: [Character] = []
        for _ in 0 ..< Int(start & 127) {
            let byte = try byte()
            for nibble in [byte >> 4, byte & 0x0F] {
                if tag == Tag.nibble8 {
                    switch nibble {
                    case 0 ... 9: chars.append(Character(String(nibble)))
                    case 10: chars.append("-")
                    case 11: chars.append(".")
                    case 15: chars.append("\0")
                    default: throw WhatsAppBinaryError.invalidNibble(nibble)
                    }
                } else {
                    chars.append(Character(UnicodeScalar(nibble < 10 ? 0x30 + nibble : 0x41 + nibble - 10)))
                }
            }
        }
        if start >> 7 != 0, !chars.isEmpty {
            chars.removeLast()
        }
        return String(chars)
    }

    mutating func node() throws -> WhatsAppNode {
        let size = try listSize(byte())
        guard size > 0, let tag = try readString(), !tag.isEmpty else { throw WhatsAppBinaryError.invalidNode }
        var node = WhatsAppNode(tag)
        for _ in 0 ..< (size - 1) >> 1 {
            guard let key = try readString() else { throw WhatsAppBinaryError.invalidNode }
            let value: WhatsAppAttribute = switch try read(asString: true) {
            case let .jid(jid): .jid(jid)
            case let .string(text): .string(text)
            case .none: .string("")
            case .bytes, .nodes: throw WhatsAppBinaryError.invalidNode
            }
            node.attributes.append(.init(key: key, value: value))
        }
        if size % 2 == 0 {
            node.content = switch try read(asString: false) {
            case .none: .none
            case let .nodes(nodes): .nodes(nodes)
            case let .bytes(data): .bytes(data)
            case let .string(text): .string(text)
            case let .jid(jid): .jid(jid)
            }
        }
        return node
    }
}
