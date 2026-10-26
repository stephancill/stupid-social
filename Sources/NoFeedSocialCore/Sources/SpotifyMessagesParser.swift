import Foundation

/// A Spotify Messages chat ("hierarchy" in the `speechless` service) with its latest message.
struct SpotifyChat: Equatable {
    let id: String
    let isGroup: Bool
    let name: String?
    let members: [String]
    let latestMessage: SpotifyChatMessage?
}

struct SpotifyChatMessage: Equatable {
    enum Content: Equatable {
        /// A shared Spotify entity URI, for in-app shares and shares sent through a link.
        case share(uri: String)
        case text(String)
        /// Rich media, chat events, invites, taste-match cards, and other kinds the feed ignores.
        case other
    }

    let id: String
    let sender: String?
    let sentAt: Date?
    let content: Content
}

/// Decodes the subset of Spotify's `speechless` protobuf messages the feed needs. Field numbers
/// come from the Android app's `com.spotify.campfire.datasource.impl.proto` classes and were
/// validated live with `scripts/spotify-web-client.py chats`.
enum SpotifyMessagesParser {
    private static let sortOrderDescending: UInt64 = 2

    /// `RetrieveLatestNodeRequest { 1: sort_order, 2: limit }`.
    static func latestChatsRequest(limit: Int) -> Data {
        var writer = ProtobufWriter()
        writer.varint(field: 1, sortOrderDescending)
        writer.varint(field: 2, UInt64(limit))
        return writer.data
    }

    /// `RetrieveLatestNodeResponse { repeated 1: LatestNodeResponse { 1: Hierarchy, 2: ClientNode } }`.
    static func parseLatestChats(_ data: Data) throws -> [SpotifyChat] {
        try ProtobufMessage(data).messages(1).compactMap { entry in
            guard let hierarchy = try entry.message(1) else { return nil }
            return try chat(hierarchy: hierarchy, latestNode: entry.message(2))
        }
    }

    /// `Hierarchy { 1: HierarchyIdentifier { 1: id }, 4: HierarchyMetadata { 5: type }, 5: Group }`.
    private static func chat(hierarchy: ProtobufMessage, latestNode: ProtobufMessage?) throws -> SpotifyChat? {
        guard let id = try hierarchy.message(1)?.string(1) else { return nil }
        let group = try hierarchy.message(5)
        return try SpotifyChat(
            id: id,
            isGroup: hierarchy.message(4)?.varint(5) == 2,
            name: group?.string(1),
            members: group?.messages(2).compactMap { $0.string(1) } ?? [],
            latestMessage: latestNode.map(message(node:)),
        )
    }

    /// `ClientNode { 1: NodeIdentifier { 1: id }, 6: ClientEventCapture, 8: MessagePayload }`.
    private static func message(node: ProtobufMessage) throws -> SpotifyChatMessage {
        let capture = try node.message(6)
        let occurredAt = try capture?.message(2)?.message(1)
        let sentAt = occurredAt.map { timestamp in
            Date(timeIntervalSince1970: TimeInterval(timestamp.varint(1) ?? 0) + TimeInterval(timestamp.varint(2) ?? 0) / 1_000_000_000)
        }
        return try SpotifyChatMessage(
            id: node.message(1)?.string(1) ?? "",
            sender: capture?.string(1),
            sentAt: sentAt,
            content: content(payload: node.message(8)),
        )
    }

    /// `MessagePayload { 1: ContributionPayload { 1: FreeText, 2: TrackedShare, 3: OffplatformTrackedShare } }`.
    private static func content(payload: ProtobufMessage?) throws -> SpotifyChatMessage.Content {
        guard let contribution = try payload?.message(1) else { return .other }
        if let uri = try contribution.message(2)?.string(1) ?? contribution.message(3)?.string(1) {
            return .share(uri: uri)
        }
        if let text = try contribution.message(1)?.string(1) {
            return .text(text)
        }
        return .other
    }
}

struct ProtobufWriter {
    private(set) var data = Data()

    mutating func varint(field: Int, _ value: UInt64) {
        append(UInt64(field << 3))
        append(value)
    }

    private mutating func append(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

/// A decoded protobuf message: varint and length-delimited fields keyed by field number.
struct ProtobufMessage {
    private enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let key = try Self.readVarint(bytes, &index)
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                try fields[field, default: []].append(.varint(Self.readVarint(bytes, &index)))
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard index + size <= bytes.count else { throw ProtobufError.truncated }
                index += size
            case 2:
                let length = try Int(Self.readVarint(bytes, &index))
                guard length >= 0, index + length <= bytes.count else { throw ProtobufError.truncated }
                fields[field, default: []].append(.bytes(Data(bytes[index ..< index + length])))
                index += length
            default:
                throw ProtobufError.unsupportedWireType
            }
        }
    }

    func varint(_ field: Int) -> UInt64? {
        for value in fields[field] ?? [] {
            if case let .varint(number) = value { return number }
        }
        return nil
    }

    func string(_ field: Int) -> String? {
        bytes(field).first.flatMap { String(data: $0, encoding: .utf8) }
    }

    func message(_ field: Int) throws -> ProtobufMessage? {
        try bytes(field).first.map(ProtobufMessage.init)
    }

    func messages(_ field: Int) throws -> [ProtobufMessage] {
        try bytes(field).map(ProtobufMessage.init)
    }

    private func bytes(_ field: Int) -> [Data] {
        (fields[field] ?? []).compactMap { value in
            if case let .bytes(data) = value { return data }
            return nil
        }
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        throw ProtobufError.truncated
    }
}

enum ProtobufError: Error {
    case truncated
    case unsupportedWireType
}
