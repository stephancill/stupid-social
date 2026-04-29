import Foundation

public enum CookieHeaderParser {
    public static func parse(_ header: String) -> [String: String] {
        header
            .split(separator: ";")
            .reduce(into: [String: String]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return }

                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                result[name] = value
            }
    }

    public static func extractXCredentials(from header: String) -> XCredentials? {
        let cookies = parse(header)
        guard let authToken = cookies["auth_token"], let ct0 = cookies["ct0"] else {
            return nil
        }

        return XCredentials(authToken: authToken, ct0: ct0)
    }
}

public struct XCredentials: Codable, Equatable, Sendable {
    public let authToken: String
    public let ct0: String

    public init(authToken: String, ct0: String) {
        self.authToken = authToken
        self.ct0 = ct0
    }
}
