import Compression
import Foundation

/// A decoded or to-be-encoded TL value. Objects carry their constructor or method name, so any constructor in
/// the schema decodes without a hand-written model; flags of type `true` decode as `.bool(true)`.
public indirect enum TLValue: Sendable, Hashable {
    case int(Int32)
    case long(Int64)
    case double(Double)
    case bytes(Data)
    case string(String)
    case bool(Bool)
    case vector([TLValue])
    case object(TLObject)

    public var int: Int32? {
        if case let .int(value) = self { value } else { nil }
    }

    public var long: Int64? {
        switch self {
        case let .long(value): value
        case let .int(value): Int64(value)
        default: nil
        }
    }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var bytes: Data? {
        if case let .bytes(value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var vector: [TLValue]? {
        if case let .vector(value) = self { value } else { nil }
    }

    public var object: TLObject? {
        if case let .object(value) = self { value } else { nil }
    }
}

public struct TLObject: Sendable, Hashable {
    public let name: String
    public var fields: [String: TLValue]

    public init(_ name: String, _ fields: [String: TLValue] = [:]) {
        self.name = name
        self.fields = fields
    }

    public subscript(_ key: String) -> TLValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    /// A field that is a vector of objects, or empty.
    public func objects(_ key: String) -> [TLObject] {
        fields[key]?.vector?.compactMap(\.object) ?? []
    }

    public func flag(_ key: String) -> Bool {
        fields[key]?.bool == true
    }
}

public enum TLError: LocalizedError {
    case unexpectedEnd
    case unknownConstructor(UInt32, expected: String)
    case unknownName(String)
    case missingField(String, in: String)
    case typeMismatch(String)
    case gzip

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd: "Telegram response ended early."
        case let .unknownConstructor(id, expected): "Unknown Telegram constructor \(String(id, radix: 16)) for \(expected)."
        case let .unknownName(name): "Unknown Telegram method or constructor \(name)."
        case let .missingField(field, name): "Missing \(field) for \(name)."
        case let .typeMismatch(type): "Unexpected value for Telegram type \(type)."
        case .gzip: "Couldn't decompress a Telegram response."
        }
    }
}

/// A parameter or result type, parsed once from the schema text.
indirect enum TLType: Hashable {
    case int, long, double, int128, int256, string, bytes, bool
    /// A `#` field holding the flag bits of the conditional fields after it.
    case flags
    /// `flags.N?true`, present only as the bit.
    case trueFlag
    /// A boxed type by name, such as `Message` or `messages.Dialogs`; `Object` and `X` take any constructor.
    case boxed(String)
    /// A constructor written without its id, such as `%Message` or `future_salt`.
    case bare(String)
    case vector(TLType, boxed: Bool)
    case conditional(field: String, bit: Int, TLType)

    static func parse(_ text: String) -> TLType {
        if let question = text.firstIndex(of: "?") {
            let condition = text[..<question].split(separator: ".")
            let inner = String(text[text.index(after: question)...])
            return .conditional(field: String(condition[0]), bit: Int(condition[1]) ?? 0, inner == "true" ? .trueFlag : parse(inner))
        }
        switch text {
        case "int": return .int
        case "long": return .long
        case "double": return .double
        case "int128": return .int128
        case "int256": return .int256
        case "string": return .string
        case "bytes": return .bytes
        case "Bool": return .bool
        case "#": return .flags
        case "true": return .trueFlag
        case "!X", "X", "Object": return .boxed("Object")
        default: break
        }
        if text.hasPrefix("Vector<") || text.hasPrefix("vector<") {
            return .vector(parse(String(text.dropFirst(7).dropLast())), boxed: text.hasPrefix("V"))
        }
        if text.hasPrefix("%") {
            return .bare(String(text.dropFirst()))
        }
        let last = text.split(separator: ".").last.map(String.init) ?? text
        if last.first?.isLowercase == true {
            return .bare(text)
        }
        return .boxed(text)
    }
}

struct TLCombinator {
    let name: String
    let id: UInt32
    let params: [(name: String, type: TLType)]
    let result: TLType
    let isFunction: Bool
}

/// The TL schema from `Resources/TelegramSchema.tl` (built by `scripts/telegram-schema.py`).
/// Immutable after `init`; the parsed tuples keep it from inferring `Sendable`.
public final class TLSchema: @unchecked Sendable {
    public static let shared: TLSchema = {
        guard let url = Bundle.module.url(forResource: "TelegramSchema", withExtension: "tl"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            fatalError("TelegramSchema.tl is missing from the NoFeedSocialCore bundle")
        }
        return TLSchema(text: text)
    }()

    public let layer: Int
    let byId: [UInt32: TLCombinator]
    let byName: [String: TLCombinator]

    init(text: String) {
        var layer = 0
        var byId: [UInt32: TLCombinator] = [:]
        var byName: [String: TLCombinator] = [:]
        var isFunction = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("// LAYER") {
                layer = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            if line == "---functions---" {
                isFunction = true
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("//"), let equals = line.range(of: " = ") else { continue }
            let head = line[..<equals.lowerBound].split(separator: " ")
            let result = String(line[equals.upperBound...].dropLast())
            let nameAndId = head[0].split(separator: "#")
            guard nameAndId.count == 2, let id = UInt32(nameAndId[1], radix: 16) else { continue }
            let params = head.dropFirst().filter { !$0.hasPrefix("{") }.map { param -> (String, TLType) in
                let parts = param.split(separator: ":", maxSplits: 1)
                return (String(parts[0]), TLType.parse(String(parts[1])))
            }
            let combinator = TLCombinator(name: String(nameAndId[0]), id: id, params: params, result: TLType.parse(result), isFunction: isFunction)
            if byId[id] == nil {
                byId[id] = combinator
            }
            // Methods, and the API's `message`, win over same-named MTProto constructors when encoding by name.
            if byName[combinator.name] == nil || isFunction || (combinator.name == "message" && result == "Message" && combinator.params.count > 4) {
                byName[combinator.name] = combinator
            }
        }
        self.layer = layer
        self.byId = byId
        self.byName = byName
    }

    /// The type a method returns; generic wrappers such as `invokeWithLayer` return their query's type.
    func resultType(of method: TLObject) throws -> TLType {
        guard let combinator = byName[method.name] else { throw TLError.unknownName(method.name) }
        if case .boxed("Object") = combinator.result, let query = method["query"]?.object {
            return try resultType(of: query)
        }
        return combinator.result
    }
}

// MARK: Encoding

struct TLWriter {
    private(set) var data = Data()
    let schema: TLSchema

    init(schema: TLSchema = .shared) {
        self.schema = schema
    }

    mutating func int32(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func int64(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func raw(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func tlBytes(_ bytes: Data) {
        let header: Int
        if bytes.count < 254 {
            data.append(UInt8(bytes.count))
            header = 1
        } else {
            data.append(254)
            data.append(UInt8(bytes.count & 0xFF))
            data.append(UInt8((bytes.count >> 8) & 0xFF))
            data.append(UInt8((bytes.count >> 16) & 0xFF))
            header = 4
        }
        data.append(bytes)
        let padding = (4 - (header + bytes.count) % 4) % 4
        data.append(Data(count: padding))
    }

    mutating func object(_ object: TLObject) throws {
        guard let combinator = schema.byName[object.name] else { throw TLError.unknownName(object.name) }
        uint32(combinator.id)
        try fields(object, combinator)
    }

    mutating func value(_ value: TLValue, as type: TLType) throws {
        switch (type, value) {
        case let (.int, .int(v)): int32(v)
        case let (.int, .long(v)): int32(Int32(truncatingIfNeeded: v))
        case let (.long, .long(v)): int64(v)
        case let (.long, .int(v)): int64(Int64(v))
        case let (.double, .double(v)): withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        case let (.int128, .bytes(v)) where v.count == 16: raw(v)
        case let (.int256, .bytes(v)) where v.count == 32: raw(v)
        case let (.string, .string(v)): tlBytes(Data(v.utf8))
        case let (.bytes, .bytes(v)): tlBytes(v)
        case let (.bool, .bool(v)): uint32(v ? 0x9972_75B5 : 0xBC79_9737)
        case let (.vector(inner, boxed), .vector(items)):
            if boxed {
                uint32(0x1CB5_C415)
            }
            int32(Int32(items.count))
            for item in items {
                try self.value(item, as: inner)
            }
        case let (.boxed, .object(object)):
            try self.object(object)
        case let (.bare(name), .object(object)):
            guard let combinator = schema.byName[object.name] ?? schema.byName[name] else { throw TLError.unknownName(object.name) }
            try fields(object, combinator)
        default:
            throw TLError.typeMismatch("\(type)")
        }
    }

    private mutating func fields(_ object: TLObject, _ combinator: TLCombinator) throws {
        for (name, type) in combinator.params {
            switch type {
            case .flags:
                var bits: UInt32 = 0
                for (other, otherType) in combinator.params {
                    guard case let .conditional(field, bit, inner) = otherType, field == name, let present = object[other] else { continue }
                    if case .trueFlag = inner, present.bool != true { continue }
                    bits |= 1 << UInt32(bit)
                }
                uint32(bits)
            case let .conditional(_, _, inner):
                guard let present = object[name] else { continue }
                if case .trueFlag = inner { continue }
                try value(present, as: inner)
            default:
                guard let present = object[name] else { throw TLError.missingField(name, in: object.name) }
                try value(present, as: type)
            }
        }
    }
}

// MARK: Decoding

struct TLReader {
    let data: Data
    var offset: Int
    let schema: TLSchema

    init(_ data: Data, schema: TLSchema = .shared) {
        self.data = data
        offset = data.startIndex
        self.schema = schema
    }

    var remaining: Int {
        data.endIndex - offset
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.endIndex else { throw TLError.unexpectedEnd }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    private mutating func fixed<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { throw TLError.unexpectedEnd }
        var value: T = 0
        for index in 0 ..< size {
            value |= T(truncatingIfNeeded: data[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }

    mutating func uint32() throws -> UInt32 {
        try fixed(UInt32.self)
    }

    mutating func int32() throws -> Int32 {
        try fixed(Int32.self)
    }

    mutating func int64() throws -> Int64 {
        try fixed(Int64.self)
    }

    func peekUInt32() -> UInt32? {
        var copy = self
        return try? copy.uint32()
    }

    mutating func tlBytes() throws -> Data {
        let first = try take(1)[0]
        let length: Int
        let header: Int
        if first < 254 {
            length = Int(first)
            header = 1
        } else {
            let size = try take(3)
            length = Int(size[size.startIndex]) | Int(size[size.startIndex + 1]) << 8 | Int(size[size.startIndex + 2]) << 16
            header = 4
        }
        let bytes = try take(length)
        _ = try take((4 - (header + length) % 4) % 4)
        return bytes
    }

    mutating func value(_ type: TLType) throws -> TLValue {
        switch type {
        case .int: return try .int(int32())
        case .long: return try .long(int64())
        case .double: return try .double(Double(bitPattern: fixed(UInt64.self)))
        case .int128: return try .bytes(take(16))
        case .int256: return try .bytes(take(32))
        case .string: return try .string(String(decoding: tlBytes(), as: UTF8.self))
        case .bytes: return try .bytes(tlBytes())
        case .flags: return try .int(int32())
        case .trueFlag: return .bool(true)
        case let .conditional(_, _, inner): return try value(inner)
        case let .vector(inner, boxed: false):
            let count = try int32()
            return try .vector((0 ..< count).map { _ in try value(inner) })
        case let .bare(name):
            guard let combinator = schema.byName[name] else { throw TLError.unknownName(name) }
            return try .object(fields(combinator))
        case .bool, .vector(_, boxed: true), .boxed:
            return try boxed(type)
        }
    }

    private mutating func boxed(_ type: TLType) throws -> TLValue {
        let id = try uint32()
        switch id {
        case 0x3072_CFA1:
            var inner = try TLReader(Self.gunzip(tlBytes()), schema: schema)
            return try inner.value(type)
        case 0x1CB5_C415:
            let inner: TLType = if case let .vector(element, _) = type { element } else { .boxed("Object") }
            let count = try int32()
            return try .vector((0 ..< count).map { _ in try value(inner) })
        case 0x9972_75B5:
            return .bool(true)
        case 0xBC79_9737:
            return .bool(false)
        default:
            guard let combinator = schema.byId[id] else { throw TLError.unknownConstructor(id, expected: "\(type)") }
            return try .object(fields(combinator))
        }
    }

    mutating func fields(_ combinator: TLCombinator) throws -> TLObject {
        var object = TLObject(combinator.name)
        var flags: [String: UInt32] = [:]
        for (name, type) in combinator.params {
            switch type {
            case .flags:
                flags[name] = try uint32()
            case let .conditional(field, bit, inner):
                guard (flags[field] ?? 0) & (1 << UInt32(bit)) != 0 else { continue }
                object[name] = try value(inner)
            default:
                object[name] = try value(type)
            }
        }
        return object
    }

    /// `gzip_packed` data: a gzip header, raw deflate, then the CRC and size, which Compression doesn't read.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw TLError.gzip }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            index += 1
        }
        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            index += 1
        }
        if flags & 0x02 != 0 {
            index += 2
        }
        let size = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        guard index < bytes.count - 8 else { throw TLError.gzip }
        let deflated = Array(bytes[index ..< bytes.count - 8])
        var output = [UInt8](repeating: 0, count: max(size, 1))
        let written = compression_decode_buffer(&output, output.count, deflated, deflated.count, nil, COMPRESSION_ZLIB)
        guard written == size else { throw TLError.gzip }
        return Data(output)
    }
}
