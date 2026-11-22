import Foundation

/// Protobuf wire format, enough to read and write the WhatsApp messages the app models by hand
/// (field numbers from whatsmeow's .proto files in third-party/whatsmeow/proto). Unknown fields are kept
/// when reading and ignored by the models.
public struct ProtoMessage: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public private(set) var fields: [(number: Int, value: Value)] = []

    public init() {}

    public init(_ data: Data) throws {
        var index = data.startIndex
        while index < data.endIndex {
            let key = try ProtoMessage.readVarint(data, &index)
            let number = Int(key >> 3)
            guard number > 0 else { throw ProtoError.malformed }
            switch key & 7 {
            case 0:
                try fields.append((number, .varint(ProtoMessage.readVarint(data, &index))))
            case 1:
                guard data.endIndex - index >= 8 else { throw ProtoError.truncated }
                let value = data[index ..< index + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                fields.append((number, .fixed64(value)))
                index += 8
            case 2:
                let length = try Int(ProtoMessage.readVarint(data, &index))
                guard length >= 0, data.endIndex - index >= length else { throw ProtoError.truncated }
                fields.append((number, .bytes(Data(data[index ..< index + length]))))
                index += length
            case 5:
                guard data.endIndex - index >= 4 else { throw ProtoError.truncated }
                let value = data[index ..< index + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                fields.append((number, .fixed32(value)))
                index += 4
            default:
                throw ProtoError.malformed
            }
        }
    }

    public static func == (lhs: ProtoMessage, rhs: ProtoMessage) -> Bool {
        lhs.fields.count == rhs.fields.count && zip(lhs.fields, rhs.fields).allSatisfy { $0.number == $1.number && $0.value == $1.value }
    }

    // MARK: Reading

    public func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    /// The last value of a field, as protobuf takes for non-repeated fields.
    func last(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    public func uint64(_ number: Int) -> UInt64? {
        switch last(number) {
        case let .varint(value), let .fixed64(value): value
        case let .fixed32(value): UInt64(value)
        default: nil
        }
    }

    public func int64(_ number: Int) -> Int64? {
        uint64(number).map { Int64(bitPattern: $0) }
    }

    public func uint32(_ number: Int) -> UInt32? {
        uint64(number).map { UInt32(truncatingIfNeeded: $0) }
    }

    public func int32(_ number: Int) -> Int32? {
        uint64(number).map { Int32(truncatingIfNeeded: $0) }
    }

    public func bool(_ number: Int) -> Bool? {
        uint64(number).map { $0 != 0 }
    }

    public func data(_ number: Int) -> Data? {
        if case let .bytes(data) = last(number) { data } else { nil }
    }

    public func string(_ number: Int) -> String? {
        data(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func message(_ number: Int) -> ProtoMessage? {
        data(number).flatMap { try? ProtoMessage($0) }
    }

    public func repeatedData(_ number: Int) -> [Data] {
        fields.compactMap { field in
            if field.number == number, case let .bytes(data) = field.value { data } else { nil }
        }
    }

    public func repeatedStrings(_ number: Int) -> [String] {
        repeatedData(number).compactMap { String(data: $0, encoding: .utf8) }
    }

    public func messages(_ number: Int) -> [ProtoMessage] {
        repeatedData(number).compactMap { try? ProtoMessage($0) }
    }

    /// A repeated scalar field, packed or not.
    public func repeatedVarints(_ number: Int) -> [UInt64] {
        fields.flatMap { field -> [UInt64] in
            guard field.number == number else { return [] }
            switch field.value {
            case let .varint(value):
                return [value]
            case let .bytes(data):
                var values: [UInt64] = []
                var index = data.startIndex
                while index < data.endIndex, let value = try? ProtoMessage.readVarint(data, &index) {
                    values.append(value)
                }
                return values
            default:
                return []
            }
        }
    }

    // MARK: Writing (fields are serialized in the order they are set)

    public mutating func set(_ number: Int, _ value: UInt64) {
        fields.append((number, .varint(value)))
    }

    public mutating func set(_ number: Int, _ value: UInt32) {
        set(number, UInt64(value))
    }

    public mutating func set(_ number: Int, _ value: Int64) {
        set(number, UInt64(bitPattern: value))
    }

    /// int32 fields encode negative values sign-extended to 64 bits.
    public mutating func set(_ number: Int, _ value: Int32) {
        set(number, UInt64(bitPattern: Int64(value)))
    }

    public mutating func set(_ number: Int, _ value: Int) {
        set(number, UInt64(bitPattern: Int64(value)))
    }

    public mutating func set(_ number: Int, _ value: Bool) {
        set(number, UInt64(value ? 1 : 0))
    }

    public mutating func set(_ number: Int, _ value: Data) {
        fields.append((number, .bytes(value)))
    }

    public mutating func set(_ number: Int, _ value: String) {
        set(number, Data(value.utf8))
    }

    public mutating func set(_ number: Int, _ value: ProtoMessage) {
        set(number, value.serialized())
    }

    public mutating func setFixed32(_ number: Int, _ value: UInt32) {
        fields.append((number, .fixed32(value)))
    }

    /// Sets the field when the value is present.
    public mutating func set(_ number: Int, ifPresent value: Data?) {
        if let value { set(number, value) }
    }

    public mutating func set(_ number: Int, ifPresent value: String?) {
        if let value { set(number, value) }
    }

    public mutating func set(_ number: Int, ifPresent value: ProtoMessage?) {
        if let value { set(number, value) }
    }

    public mutating func remove(_ number: Int) {
        fields.removeAll { $0.number == number }
    }

    public func serialized() -> Data {
        var output = Data()
        for (number, value) in fields {
            switch value {
            case let .varint(value):
                ProtoMessage.writeVarint(UInt64(number << 3), into: &output)
                ProtoMessage.writeVarint(value, into: &output)
            case let .fixed64(value):
                ProtoMessage.writeVarint(UInt64(number << 3 | 1), into: &output)
                withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
            case let .bytes(data):
                ProtoMessage.writeVarint(UInt64(number << 3 | 2), into: &output)
                ProtoMessage.writeVarint(UInt64(data.count), into: &output)
                output.append(data)
            case let .fixed32(value):
                ProtoMessage.writeVarint(UInt64(number << 3 | 5), into: &output)
                withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    static func readVarint(_ data: Data, _ index: inout Data.Index) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.endIndex, shift < 64 else { throw ProtoError.truncated }
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    static func writeVarint(_ value: UInt64, into output: inout Data) {
        var value = value
        while value >= 0x80 {
            output.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
    }
}

public enum ProtoError: Error, Equatable {
    case truncated
    case malformed
}
