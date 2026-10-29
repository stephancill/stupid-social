import Foundation

/// One tracked event or error, as sent to `POST /v1/events`.
struct MetricEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case event
        case error
    }

    var type: Kind
    var name: String
    /// Unix time in milliseconds.
    var time: Int64
    var sessionId: String
    var props: [String: String]
    var value: Double?
    var message: String?
}

/// Describes the install sending a batch. Nothing here identifies a person.
struct MetricContext: Codable, Equatable {
    var appVersion: String
    var build: String
    /// Empty until resolved; stamped before sending.
    var environment: String
    var platform: String
    var osVersion: String
    var deviceModel: String
    var installId: String
}

/// Events that share a context. A version update starts a new batch, so queued
/// events are still reported with the version that produced them.
struct EventBatch: Codable, Equatable {
    var context: MetricContext
    var events: [MetricEvent]
}

/// The server's rules for names, prop keys and values (`src/schemas.ts`).
enum Limits {
    static let maxProps = 8
    static let maxNameLength = 64
    static let maxPropKeyLength = 32
    static let maxPropValueLength = 64
    static let maxMessageLength = 256
    static let maxEventsPerRequest = 200
    static let maxQueuedEvents = 2000
    static let maxEventAge: TimeInterval = 7 * 24 * 60 * 60

    static func isValidToken(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength && value.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || "_.:-".contains(character))
        }
    }

    /// Drops invalid keys and props beyond the limit (by key order) and truncates values.
    static func sanitize(_ props: [String: String]) -> [String: String] {
        let valid = props.keys.filter { isValidToken($0, maxLength: maxPropKeyLength) }.sorted().prefix(maxProps)
        return Dictionary(uniqueKeysWithValues: valid.map { ($0, String(props[$0]!.prefix(maxPropValueLength))) })
    }
}
