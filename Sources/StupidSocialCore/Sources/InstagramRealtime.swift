import Foundation

/// Meta's gateway framing (DGW) on `gateway.instagram.com/ws/lightspeed`, as the web client sends it (validated
/// with `scripts/instagram-web-client.py direct-live`, observed 2026-11-20; frame types from the web client's
/// `DGWConstants`). Ping and pong are one byte; every other frame is its type, a stream id (2 bytes,
/// little-endian), the payload's length (3 bytes, little-endian) and the payload. A data frame's payload starts
/// with a 16-bit little-endian id whose top bit asks for an ack; the ack frame carries the id back.
enum InstagramDGW {
    static let establishStream: UInt8 = 15
    static let data: UInt8 = 13
    static let ack: UInt8 = 12
    static let ping: UInt8 = 9
    static let pong: UInt8 = 10

    struct Frame: Equatable {
        let kind: UInt8
        let payload: Data
    }

    static func frame(_ kind: UInt8, _ payload: Data) -> Data {
        var data = Data([kind, 0, 0])
        let length = payload.count
        data.append(contentsOf: [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF)])
        data.append(payload)
        return data
    }

    /// A data frame asking for an ack, with id 0.
    static func dataFrame(_ body: Data) -> Data {
        frame(data, Data([0x00, 0x80]) + body)
    }

    static func ackFrame(id: UInt16) -> Data {
        frame(ack, Data([UInt8(id & 0xFF), UInt8(id >> 8)]))
    }

    /// The frames in one WebSocket message; a truncated frame ends the list.
    static func frames(_ message: Data) -> [Frame] {
        let bytes = [UInt8](message)
        var frames: [Frame] = []
        var index = 0
        while index < bytes.count {
            let kind = bytes[index]
            if kind == ping || kind == pong {
                frames.append(Frame(kind: kind, payload: Data()))
                index += 1
                continue
            }
            guard index + 6 <= bytes.count else { break }
            let length = Int(bytes[index + 3]) | Int(bytes[index + 4]) << 8 | Int(bytes[index + 5]) << 16
            guard index + 6 + length <= bytes.count else { break }
            frames.append(Frame(kind: kind, payload: Data(bytes[(index + 6) ..< (index + 6 + length)])))
            index += 6 + length
        }
        return frames
    }

    /// A data frame's id and whether it asks for an ack, and its body after them.
    static func split(dataPayload payload: Data) -> (id: UInt16, wantsAck: Bool, body: Data)? {
        guard payload.count >= 2 else { return nil }
        let bytes = [UInt8](payload.prefix(2))
        let value = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        return (value & 0x7FFF, value & 0x8000 != 0, payload.dropFirst(2))
    }
}

/// One change Instagram pushes for Direct: an `IGDSlideDeltaProcessorQuery` result's `slide_delta_processor`
/// item, such as `SlideUQPPNewMessage` with the new message (shaped like a thread query's message).
struct InstagramDirectDelta {
    let typename: String
    let threadFbid: String?
    let message: InstagramDirectMessage?

    init(typename: String, threadFbid: String?, message: InstagramDirectMessage?) {
        self.typename = typename
        self.threadFbid = threadFbid
        self.message = message
    }

    init?(_ object: [String: Any]) {
        guard let typename = object["__typename"] as? String else { return nil }
        let messageObject = object["message"] as? [String: Any]
        self.typename = typename
        threadFbid = object["thread_fbid"] as? String ?? messageObject?["thread_fbid"] as? String
        message = messageObject.flatMap { messageObject in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return (try? JSONSerialization.data(withJSONObject: messageObject)).flatMap { try? decoder.decode(InstagramDirectMessage.self, from: $0) }
        }
    }
}

/// The Direct sync payload in a data frame's `payload` (base64 protobuf): field 2 holds field 3 entries for pushed
/// changes, each { 1: database, 2: JSON array of `IGDSlideDeltaProcessorQuery` results, 3: seq id }, and field 1
/// entries { 1: database, 2, 3: seq id } in the answer to the sync request.
enum InstagramDirectSync {
    static func deltas(fromPayload payload: Data) -> (deltas: [InstagramDirectDelta], seqId: Int?) {
        var deltas: [InstagramDirectDelta] = []
        var newest: Int?
        for (number, value) in protobufFields(payload) where number == 2 {
            guard case let .bytes(inner) = value else { continue }
            for (_, entry) in protobufFields(inner) {
                guard case let .bytes(entryData) = entry else { continue }
                for (field, item) in protobufFields(entryData) {
                    switch (field, item) {
                    case let (2, .bytes(json)) where json.first == UInt8(ascii: "["):
                        let results = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []
                        for result in results {
                            let items = ((result["data"] as? [String: Any])?["slide_delta_processor"] as? [[String: Any]]) ?? []
                            deltas += items.compactMap(InstagramDirectDelta.init)
                        }
                    case let (3, .varint(seq)):
                        newest = max(newest ?? 0, Int(seq))
                    default:
                        break
                    }
                }
            }
        }
        return (deltas, newest)
    }

    enum Field {
        case varint(UInt64)
        case bytes(Data)
    }

    /// A protobuf message's top-level fields; stops at anything malformed or of another wire type.
    static func protobufFields(_ data: Data) -> [(Int, Field)] {
        let bytes = [UInt8](data)
        var fields: [(Int, Field)] = []
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return fields }
                fields.append((number, .varint(value)))
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return fields }
                fields.append((number, .bytes(Data(bytes[index ..< index + Int(length)]))))
                index += Int(length)
            default:
                return fields
            }
        }
        return fields
    }
}
