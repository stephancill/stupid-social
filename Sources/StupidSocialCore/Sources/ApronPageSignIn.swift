import CryptoKit
import Foundation
import StupidSocialPush

/// A way to sign in to an Apron server that the app offers (§3.2).
public enum ApronSignInMethod: Hashable, Sendable {
    /// `webauthn` login on the server's passkey page (§4.10.1).
    case passkey
    /// `webauthn` registration on the passkey page: a new account with a new passkey.
    case createPasskey
    /// `external` sign-in on the server's page (§4.12), the way the user chose with `ext:auth_external`, or the
    /// server's one way without it.
    case external(ApronExternalSignInOption?)
    case token
    case guest

    /// Signs in on a page of the server, in a sign-in session.
    public var usesPage: Bool {
        switch self {
        case .passkey, .createPasskey, .external: true
        case .token, .guest: false
        }
    }
}

/// What a server's `server` frame says about signing in: its schemes, their labels, and the ways external sign-in
/// can go.
public struct ApronSignInOptions: Codable, Equatable, Sendable {
    public var auth: [String]
    public var signup: [String]?
    public var labels: [String: String]
    public var externalOptions: [ApronExternalSignInOption]

    public init(server: ApronServerInfo) {
        auth = server.auth
        signup = server.signup
        labels = server.labels ?? [:]
        // Options come only with the extension, and only when there are two or more (`ext:auth_external`).
        let options = server.has("ext:auth_external") ? server.ext?.externalSignInOptions ?? [] : []
        externalOptions = options.count >= 2 ? options : []
    }

    /// The methods the app can use, in the server's order: `auth`, then schemes only in `signup` (absent: same
    /// as `auth`). The passkey page's `register` is offered where `webauthn` creates accounts. Email isn't
    /// supported.
    public var methods: [ApronSignInMethod] {
        let signupSchemes = signup ?? auth
        var methods: [ApronSignInMethod] = []
        for scheme in auth + signupSchemes {
            let added: [ApronSignInMethod] = switch scheme {
            case "webauthn":
                (auth.contains(scheme) ? [.passkey] : []) + (signupSchemes.contains(scheme) ? [.createPasskey] : [])
            case "external":
                externalOptions.isEmpty ? [.external(nil)] : externalOptions.map { .external($0) }
            case "token": [.token]
            case "guest": [.guest]
            default: []
            }
            for method in added where !methods.contains(method) {
                methods.append(method)
            }
        }
        return methods
    }

    /// The button title for a method, with the server's label where it gives one (§3.2).
    public func title(for method: ApronSignInMethod) -> String {
        switch method {
        case .passkey: labels["webauthn"].map { "Sign In with \($0)" } ?? "Sign In with Passkey"
        case .createPasskey: "Create Account with Passkey"
        case let .external(option?): "Sign In with \(option.label)"
        case .external(nil): labels["external"].map { "Sign In with \($0)" } ?? "Sign In on the Server's Website"
        case .token: labels["token"].map { "Sign In with \($0)" } ?? "Sign In with Token"
        case .guest: labels["guest"].map { "Sign In with \($0)" } ?? "Join as Guest"
        }
    }

    /// `labels.external`, a heading for the ways external sign-in can go (`ext:auth_external`).
    public var externalHeading: String? {
        externalOptions.isEmpty ? nil : labels["external"]
    }
}

/// A server before signing in to it: its address and what its `server` frame says (§3.1).
public struct ApronServerPreview: Equatable, Sendable {
    public let serverURL: URL
    public let server: ApronServerInfo

    public var signIn: ApronSignInOptions {
        ApronSignInOptions(server: server)
    }

    public var displayTitle: String {
        server.displayTitle(serverURL: serverURL)
    }
}

/// One sign-in on a page of the server: the passkey page (§4.10.1) or external sign-in (§4.12). The app opens
/// `authorizationURL` in a sign-in session, and redeems the code it gets back (recipes/native_passkeys.md).
/// Stupid Social is on no server's domain, so it never runs the WebAuthn ceremony itself.
public struct ApronPageSignIn: Sendable {
    /// The app's own `client_id` (§4.12.2), its bundle id.
    public static let clientId = "tech.stupid.StupidSocial"
    /// A scheme with a `.`, which servers accept as a `redirect_uri` (§4.12.3).
    public static let callbackScheme = "tech.stupid.stupidsocial"
    static let redirectURI = "\(callbackScheme):/apron/signed-in"

    public let authorizationURL: URL
    let state: String
    let codeVerifier: String

    /// The authorization request: the page's own query kept, then the code grant, PKCE S256, `state` and
    /// `resource`, the server's origin worked out from the address the app connected to (§4.12.1, §4.12.2).
    init(pageURL: String, serverURL: URL) throws {
        guard let page = URL(string: pageURL), Self.isAllowedPage(page),
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let resource = Self.origin(serverURL: serverURL)
        else {
            throw ApronError.invalidSignInPage
        }
        codeVerifier = Self.randomString(bytes: 32)
        state = Self.randomString(bytes: 16)
        let challenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString
        var added = URLComponents()
        added.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        // `+` is a space in form-encoded queries, so ours is escaped; the other reserved characters already are.
        let ours = added.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        // The page's own query is kept exactly as sent, such as `name=Ada+L` with its `+` for a space (§4.12.1).
        components.percentEncodedQuery = [components.percentEncodedQuery, ours].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "&")
        guard let url = components.url else { throw ApronError.invalidSignInPage }
        authorizationURL = url
    }

    /// The code from the page's redirect, once `state` is checked to be ours (§4.12.2).
    func code(from callbackURL: URL) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard callbackURL.scheme?.lowercased() == Self.callbackScheme, value("state") == state else {
            throw ApronError.signInFailed
        }
        if let error = value("error") {
            throw error == "access_denied" ? ApronError.signInDeclined : ApronError.signInFailed
        }
        guard let code = value("code"), !code.isEmpty else { throw ApronError.signInFailed }
        return code
    }

    /// `https`, or `http` on a loopback host; anything else, such as `javascript:`, is refused (§4.12.1).
    static func isAllowedPage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host()?.isEmpty == false
        case "http": isLoopback(url.host())
        default: false
        }
    }

    /// `https://` plus the host and any port of the server's address, or `http://` for `ws://` on a loopback
    /// host (§4.12.1).
    static func origin(serverURL: URL) -> String? {
        guard let components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false), let host = components.host, !host.isEmpty else {
            return nil
        }
        let insecure = components.scheme?.lowercased() == "ws"
        guard !insecure || isLoopback(host) else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(insecure ? "http" : "https")://\(bracketed.lowercased())\(port)"
    }

    private static func isLoopback(_ host: String?) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host?.lowercased() ?? "")
    }

    private static func randomString(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncodedString
    }
}
