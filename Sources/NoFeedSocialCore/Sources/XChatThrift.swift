import Foundation

/// A Thrift binary-protocol value, as XChat's events are encoded (base64 in GraphQL, raw on the socket).
/// Structs keep fields by id; the XChat models read the ids they know and ignore the rest.
public indirect enum ThriftValue: Equatable, Sendable {
    case bool(Bool)
    case byte(Int8)
    case i16(Int16)
    case i32(Int32)
    case i64(Int64)
    case double(Double)
    case binary(Data)
    case structure(ThriftStruct)
    case map(keyType: UInt8, valueType: UInt8, [ThriftValue: ThriftValue])
    case set(elementType: UInt8, [ThriftValue])
    case list(elementType: UInt8, [ThriftValue])

    var typeCode: UInt8 {
        switch self {
        case .bool: 2
        case .byte: 3
        case .double: 4
        case .i16: 6
        case .i32: 8
        case .i64: 10
        case .binary: 11
        case .structure: 12
        case .map: 13
        case .set: 14
        case .list: 15
        }
    }
}

extension ThriftValue: Hashable {}

public struct ThriftStruct: Hashable, Sendable {
    var fields: [Int16: ThriftValue]

    init(_ fields: [Int16: ThriftValue] = [:]) {
        self.fields = fields
    }

    subscript(id: Int16) -> ThriftValue? {
        get { fields[id] }
        set { fields[id] = newValue }
    }

    func data(_ id: Int16) -> Data? {
        if case let .binary(data) = fields[id] { data } else { nil }
    }

    func string(_ id: Int16) -> String? {
        data(id).flatMap { String(data: $0, encoding: .utf8) }
    }

    func structure(_ id: Int16) -> ThriftStruct? {
        if case let .structure(value) = fields[id] { value } else { nil }
    }

    func list(_ id: Int16) -> [ThriftValue] {
        switch fields[id] {
        case let .list(_, items), let .set(_, items): items
        default: []
        }
    }

    func structures(_ id: Int16) -> [ThriftStruct] {
        list(id).compactMap { if case let .structure(value) = $0 { value } else { nil } }
    }

    func bool(_ id: Int16) -> Bool? {
        if case let .bool(value) = fields[id] { value } else { nil }
    }

    func int(_ id: Int16) -> Int64? {
        switch fields[id] {
        case let .byte(value): Int64(value)
        case let .i16(value): Int64(value)
        case let .i32(value): Int64(value)
        case let .i64(value): value
        default: nil
        }
    }

    /// The set field of a Thrift union, such as `MessageEventDetail`.
    var unionCase: (id: Int16, value: ThriftStruct)? {
        fields.lazy.compactMap { id, value in
            if case let .structure(structure) = value { (id, structure) } else { nil }
        }.first
    }
}

enum ThriftError: LocalizedError {
    case truncated
    case unknownType(UInt8)

    var errorDescription: String? {
        switch self {
        case .truncated: "XChat data ended early."
        case let .unknownType(type): "XChat data has an unknown Thrift type \(type)."
        }
    }
}

enum ThriftCoder {
    static func decode(_ data: Data) throws -> ThriftStruct {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.structure()
    }

    static func encode(_ structure: ThriftStruct) -> Data {
        var out = [UInt8]()
        write(structure, to: &out)
        return Data(out)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw ThriftError.truncated }
            defer { offset += count }
            return bytes[offset ..< offset + count]
        }

        mutating func integer(_ size: Int) throws -> Int64 {
            let slice = try take(size)
            var value: UInt64 = 0
            for byte in slice {
                value = value << 8 | UInt64(byte)
            }
            // Sign-extend from `size` bytes.
            let shift = UInt64(64 - size * 8)
            return Int64(bitPattern: value << shift) >> Int64(shift)
        }

        mutating func value(type: UInt8) throws -> ThriftValue {
            switch type {
            case 2: return try .bool(take(1).first != 0)
            case 3: return try .byte(Int8(integer(1)))
            case 4: return try .double(Double(bitPattern: UInt64(bitPattern: integer(8))))
            case 6: return try .i16(Int16(integer(2)))
            case 8: return try .i32(Int32(integer(4)))
            case 10: return try .i64(integer(8))
            case 11: return try .binary(Data(take(Int(integer(4)))))
            case 12: return try .structure(structure())
            case 13:
                let keyType = try take(1).first!, valueType = try take(1).first!
                var entries: [ThriftValue: ThriftValue] = [:]
                for _ in try 0 ..< max(0, integer(4)) {
                    let key = try value(type: keyType)
                    entries[key] = try value(type: valueType)
                }
                return .map(keyType: keyType, valueType: valueType, entries)
            case 14, 15:
                let elementType = try take(1).first!
                let count = try integer(4)
                var items: [ThriftValue] = []
                for _ in 0 ..< max(0, count) {
                    try items.append(value(type: elementType))
                }
                return type == 14 ? .set(elementType: elementType, items) : .list(elementType: elementType, items)
            default:
                throw ThriftError.unknownType(type)
            }
        }

        mutating func structure() throws -> ThriftStruct {
            var result = ThriftStruct()
            while true {
                let type = try take(1).first!
                if type == 0 { return result }
                let id = try Int16(integer(2))
                result[id] = try value(type: type)
            }
        }
    }

    private static func write(_ structure: ThriftStruct, to out: inout [UInt8]) {
        // Field order doesn't matter to Thrift; ascending ids keep the bytes stable for tests.
        for (id, value) in structure.fields.sorted(by: { $0.key < $1.key }) {
            out.append(value.typeCode)
            append(Int64(id), size: 2, to: &out)
            write(value, to: &out)
        }
        out.append(0)
    }

    private static func write(_ value: ThriftValue, to out: inout [UInt8]) {
        switch value {
        case let .bool(value): out.append(value ? 1 : 0)
        case let .byte(value): out.append(UInt8(bitPattern: value))
        case let .double(value): append(Int64(bitPattern: value.bitPattern), size: 8, to: &out)
        case let .i16(value): append(Int64(value), size: 2, to: &out)
        case let .i32(value): append(Int64(value), size: 4, to: &out)
        case let .i64(value): append(value, size: 8, to: &out)
        case let .binary(data):
            append(Int64(data.count), size: 4, to: &out)
            out.append(contentsOf: data)
        case let .structure(structure): write(structure, to: &out)
        case let .map(keyType, valueType, entries):
            out.append(keyType)
            out.append(valueType)
            append(Int64(entries.count), size: 4, to: &out)
            for (key, value) in entries {
                write(key, to: &out)
                write(value, to: &out)
            }
        case let .set(elementType, items), let .list(elementType, items):
            out.append(elementType)
            append(Int64(items.count), size: 4, to: &out)
            for item in items {
                write(item, to: &out)
            }
        }
    }

    private static func append(_ value: Int64, size: Int, to out: inout [UInt8]) {
        for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: value >> Int64(shift)))
        }
    }
}

extension ThriftValue {
    static func string(_ value: String) -> ThriftValue {
        .binary(Data(value.utf8))
    }

    static func structs(_ items: [ThriftStruct]) -> ThriftValue {
        .list(elementType: 12, items.map { .structure($0) })
    }
}
