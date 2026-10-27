import Foundation

/// A link to an Apron server, or to a room, message or user on one (PROTOCOL.md Appendix A.4, and link.apron.chat's
/// SPEC.md), in the web form `https://link.apron.chat/#server=…&room=…` or the URI form `apron:?server=…&room=…`.
/// Opening one only shows its place: nothing is sent, joined or signed in without the user's action.
public struct ApronLink: Hashable, Sendable {
    public let serverURL: URL
    /// A `room_id`, also of a thread.
    public let room: String?
    /// A `message_id` in `room`.
    public let message: String?
    /// A `user_id`; with `room`, of a member of that room.
    public let user: String?
    /// A sign-in token or an invite, presented with `scheme: "token"` (§4.11.2, Appendix B.3). Only servers write
    /// links with one, so the app never copies or shares it.
    public let token: String?

    public init(serverURL: URL, room: String? = nil, message: String? = nil, user: String? = nil, token: String? = nil) {
        self.serverURL = serverURL
        self.room = room
        self.message = message
        self.user = user
        self.token = token
    }

    public enum ParseError: LocalizedError, Equatable {
        case missingServer
        case unsupportedTransport(String)
        case invalidServer
        /// A `ws` server off the user's own device.
        case insecureServer
        case credentialInQuery
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .missingServer: "This Apron link doesn't say which server it's for."
            case let .unsupportedTransport(transport): "This Apron link needs the \(transport) transport, which this app doesn't support."
            case .invalidServer: "This Apron link's server address isn't valid."
            case .insecureServer: "This Apron link uses an unencrypted connection to a server that isn't on this device."
            case .credentialInQuery: "This sign-in link is malformed: its token was sent to link.apron.chat, so it can't be trusted."
            case let .invalidValue(key): "This Apron link's \(key) isn't valid."
            }
        }
    }

    public static let webPrefix = "https://link.apron.chat/#"

    /// Whether the URL is in either link form, valid or not.
    public static func isLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "apron": true
        case "https": url.host()?.lowercased() == "link.apron.chat" && (url.path().isEmpty || url.path() == "/")
        default: false
        }
    }

    /// Parses either form. A link without `server` refers to `contentServer`, the server that sent the content
    /// holding it, and is refused anywhere else (SPEC.md §5).
    public init(url: URL, contentServer: URL? = nil) throws {
        guard Self.isLink(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ParseError.missingServer
        }
        var pairs: [(key: String, value: String)]
        if url.scheme?.lowercased() == "apron" {
            pairs = Self.pairs(components.percentEncodedQuery)
        } else {
            pairs = Self.pairs(components.percentEncodedFragment)
            // Keys in the query count after the fragment's, but its host has already seen them, so never a token.
            let query = Self.pairs(components.percentEncodedQuery)
            guard !query.contains(where: { $0.key == "token" }) else { throw ParseError.credentialInQuery }
            pairs += query
        }
        // The first value of a repeated key wins.
        var keys: [String: String] = [:]
        for pair in pairs where keys[pair.key] == nil {
            keys[pair.key] = pair.value
        }

        if let server = keys["server"] {
            serverURL = try Self.validatedServer(server)
        } else if let contentServer {
            serverURL = contentServer
        } else {
            throw ParseError.missingServer
        }
        room = try keys["room"].map { try Self.validatedId($0, key: "room") }
        user = try keys["user"].map { try Self.validatedId($0, key: "user") }
        if let message = keys["message"] {
            guard room != nil, Self.isMessageId(message) else { throw ParseError.invalidValue("message") }
            self.message = message
        } else {
            message = nil
        }
        if let token = keys["token"] {
            guard !token.isEmpty else { throw ParseError.invalidValue("token") }
            self.token = token
        } else {
            token = nil
        }
    }

    /// The web form, for sharing. It never carries a token.
    public var webURL: URL {
        var parts = ["server=\(Self.encode(serverURL.absoluteString))"]
        if let room { parts.append("room=\(Self.encode(room))") }
        if let message { parts.append("message=\(Self.encode(message))") }
        if let user { parts.append("user=\(Self.encode(user))") }
        return URL(string: Self.webPrefix + parts.joined(separator: "&"))!
    }

    /// The server's host, with its port, in ASCII form so lookalike internationalized names stand out.
    public var host: String {
        let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        let host = components?.encodedHost ?? serverURL.host() ?? serverURL.absoluteString
        return components?.port.map { "\(host):\($0)" } ?? host
    }

    /// Whether the server is on this device or a private network, where a link deserves a stronger warning.
    public var isLocalServer: Bool {
        let host = Self.bareHost(serverURL)
        if Self.isLoopback(host) || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case let (172, second): return (16 ... 31).contains(second)
            default: return false
            }
        }
        // IPv6 unique local (fc00::/7) and link-local (fe80::/10) addresses.
        return host.contains(":") && (host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb"))
    }

    /// A `room` or `user` value for display: characters that hide or reorder text are escaped, and long values cut
    /// in the middle (SPEC.md §6).
    public static func displayValue(_ value: String, limit: Int = 48) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned:
                escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        guard escaped.count > limit else { return escaped }
        let half = (limit - 1) / 2
        return "\(escaped.prefix(half))…\(escaped.suffix(half))"
    }

    // MARK: - Parsing

    /// `application/x-www-form-urlencoded` pairs, where a bare `+` is a space.
    private static func pairs(_ encoded: String?) -> [(key: String, value: String)] {
        guard let encoded else { return [] }
        return encoded.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Letters, digits, `-`, `.`, `_`, `~`, `:` and `/` stay as they are (SPEC.md §4).
    private static let unencoded = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unencoded) ?? value
    }

    /// `wss`, or `ws` on a loopback host; other transports are named so the user knows what the link needs.
    private static func validatedServer(_ value: String) throws -> URL {
        guard let colon = value.firstIndex(of: ":") else { throw ParseError.invalidServer }
        let transport = value[..<colon]
        guard !transport.isEmpty, transport.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else {
            throw ParseError.invalidServer
        }
        guard transport == "wss" || transport == "ws" else { throw ParseError.unsupportedTransport(String(transport)) }
        guard var components = URLComponents(string: value), components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil
        else { throw ParseError.invalidServer }
        // Saved servers always have a path, as `ApronService.normalizeServerURL` writes them.
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let url = components.url else { throw ParseError.invalidServer }
        if transport == "ws", !isLoopback(bareHost(url)) {
            throw ParseError.insecureServer
        }
        return url
    }

    private static func bareHost(_ url: URL) -> String {
        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        return host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// `localhost`, a name under it, `127.0.0.0/8`, or `::1`.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil } && octets[0] == "127"
    }

    /// Not empty, and no whitespace or control characters.
    private static func validatedId(_ value: String, key: String) throws -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.properties.generalCategory != .control }) else {
            throw ParseError.invalidValue(key)
        }
        return value
    }

    /// A positive decimal integer below 2^53, with no leading zero.
    static func isMessageId(_ value: String) -> Bool {
        guard let first = value.first, first != "0", value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(value) else { return false }
        return number < 1 << 53
    }
}
