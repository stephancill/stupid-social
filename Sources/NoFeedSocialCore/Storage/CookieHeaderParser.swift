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

    public static func extractInstagramCredentials(from header: String) -> InstagramCredentials? {
        let cookies = parse(header)
        guard let sessionId = cookies["sessionid"],
              let csrfToken = cookies["csrftoken"],
              let dsUserId = cookies["ds_user_id"]
        else {
            return nil
        }

        return InstagramCredentials(
            sessionId: sessionId,
            csrfToken: csrfToken,
            dsUserId: dsUserId,
            mid: cookies["mid"],
            rur: cookies["rur"],
            igDid: cookies["ig_did"]
        )
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

public struct InstagramCredentials: Codable, Equatable, Sendable {
    public let sessionId: String
    public let csrfToken: String
    public let dsUserId: String
    public let mid: String?
    public let rur: String?
    public let igDid: String?

    public init(sessionId: String, csrfToken: String, dsUserId: String, mid: String?, rur: String? = nil, igDid: String? = nil) {
        self.sessionId = sessionId
        self.csrfToken = csrfToken
        self.dsUserId = dsUserId
        self.mid = mid
        self.rur = rur
        self.igDid = igDid
    }
}

public struct SpotifyCredentials: Codable, Equatable, Sendable {
    public let bearerToken: String
    public let clientToken: String
    public let spDC: String
    public let spT: String?
    public let accessTokenExpiresAt: Date?
    public let username: String?

    public init(
        bearerToken: String,
        clientToken: String,
        spDC: String,
        spT: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        username: String?
    ) {
        self.bearerToken = bearerToken
        self.clientToken = clientToken
        self.spDC = spDC
        self.spT = spT
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.username = username
    }

    public func updatingWebPlayerToken(_ token: String, expiresAt: Date?) -> SpotifyCredentials {
        SpotifyCredentials(
            bearerToken: token,
            clientToken: clientToken,
            spDC: spDC,
            spT: spT,
            accessTokenExpiresAt: expiresAt,
            username: username
        )
    }
}
