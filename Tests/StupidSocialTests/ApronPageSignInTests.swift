import CryptoKit
import Foundation
@testable import StupidSocialCore
import StupidSocialPush
import XCTest

final class ApronPageSignInTests: XCTestCase {
    private func server(_ json: String) throws -> ApronServerInfo {
        try JSONDecoder().decode(ApronServerInfo.self, from: Data(json.utf8))
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    /// The demo server (observed 2026-11-17): passkeys sign in and create accounts, tokens resume, guests read.
    func testDemoServerMethodsFollowAuthThenSignup() throws {
        let options = try ApronSignInOptions(server: server(#"{"apron":10,"auth":["webauthn","token","guest"],"signup":["webauthn","token"]}"#))
        XCTAssertEqual(options.methods, [.passkey, .createPasskey, .token, .guest])
    }

    /// aprond: `token` only resumes, and `guest` and `webauthn` create accounts.
    func testSignupOnlySchemesComeAfterAuth() throws {
        let options = try ApronSignInOptions(server: server(#"{"apron":10,"auth":["token"],"signup":["guest","webauthn","email"]}"#))
        XCTAssertEqual(options.methods, [.token, .guest, .createPasskey])
    }

    func testExternalOptionsNeedTheExtensionAndTwoOptions() throws {
        let frame = #"""
        {"apron":10,"auth":["external","token"],"labels":{"external":"Acme login"},"capabilities":["ext:auth_external"],
         "ext":{"auth_external":{"options":[{"id":"sso","label":"Acme SSO"},{"id":"github","label":"GitHub"}]}}}
        """#
        let options = try ApronSignInOptions(server: server(frame))
        let sso = ApronExternalSignInOption(id: "sso", label: "Acme SSO")
        let github = ApronExternalSignInOption(id: "github", label: "GitHub")
        XCTAssertEqual(options.methods, [.external(sso), .external(github), .token])
        XCTAssertEqual(options.title(for: .external(github)), "Sign In with GitHub")
        XCTAssertEqual(options.externalHeading, "Acme login")

        // Without the capability, one external choice with its label.
        let plain = try ApronSignInOptions(server: server(frame.replacingOccurrences(of: #""capabilities":["ext:auth_external"],"#, with: "")))
        XCTAssertEqual(plain.methods, [.external(nil), .token])
        XCTAssertEqual(plain.title(for: .external(nil)), "Sign In with Acme login")
        XCTAssertNil(plain.externalHeading)
    }

    func testAuthorizationRequestKeepsThePageQuery() throws {
        let request = try ApronPageSignIn(pageURL: "https://chat.example/passkey?action=register&name=Ada+L", serverURL: XCTUnwrap(URL(string: "wss://chat.example/ws")))
        let items = query(request.authorizationURL)
        XCTAssertEqual(request.authorizationURL.host(), "chat.example")
        XCTAssertEqual(request.authorizationURL.path(), "/passkey")
        XCTAssertEqual(items["action"], "register")
        // The page's query is kept as sent: its `+` is the server's space (observed on the demo, 2026-11-17).
        XCTAssertTrue(request.authorizationURL.absoluteString.hasPrefix("https://chat.example/passkey?action=register&name=Ada+L&response_type=code&"))
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "tech.stupid.StupidSocial")
        XCTAssertEqual(items["redirect_uri"], "tech.stupid.stupidsocial:/apron/signed-in")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], Data(SHA256.hash(data: Data(request.codeVerifier.utf8))).base64URLEncodedString)
        XCTAssertEqual(items["state"], request.state)
        XCTAssertEqual(items["resource"], "https://chat.example")
    }

    func testResourceIsTheServerOrigin() throws {
        XCTAssertEqual(try ApronPageSignIn.origin(serverURL: XCTUnwrap(URL(string: "wss://Chat.Example:8443/ws"))), "https://chat.example:8443")
        XCTAssertEqual(try ApronPageSignIn.origin(serverURL: XCTUnwrap(URL(string: "ws://localhost:8080/ws"))), "http://localhost:8080")
        XCTAssertNil(try ApronPageSignIn.origin(serverURL: XCTUnwrap(URL(string: "ws://chat.example/ws"))))
    }

    func testRefusesPagesThatArentHTTPS() throws {
        let serverURL = try XCTUnwrap(URL(string: "wss://chat.example/ws"))
        for page in ["javascript:alert(1)", "http://chat.example/passkey", "data:text/html,hi", "/passkey"] {
            XCTAssertThrowsError(try ApronPageSignIn(pageURL: page, serverURL: serverURL), page) { error in
                XCTAssertEqual(error as? ApronError, .invalidSignInPage)
            }
        }
        XCTAssertNoThrow(try ApronPageSignIn(pageURL: "http://localhost:8080/passkey", serverURL: XCTUnwrap(URL(string: "ws://localhost:8080/ws"))))
    }

    func testCodeNeedsOurState() throws {
        let request = try ApronPageSignIn(pageURL: "https://chat.example/passkey?action=login", serverURL: XCTUnwrap(URL(string: "wss://chat.example/ws")))
        let base = "tech.stupid.stupidsocial:/apron/signed-in"
        XCTAssertEqual(try request.code(from: XCTUnwrap(URL(string: "\(base)?code=Hk41&state=\(request.state)&iss=https://chat.example"))), "Hk41")
        XCTAssertThrowsError(try request.code(from: XCTUnwrap(URL(string: "\(base)?code=Hk41&state=other")))) { error in
            XCTAssertEqual(error as? ApronError, .signInFailed)
        }
        XCTAssertThrowsError(try request.code(from: XCTUnwrap(URL(string: "\(base)?error=access_denied&state=\(request.state)")))) { error in
            XCTAssertEqual(error as? ApronError, .signInDeclined)
        }
        XCTAssertThrowsError(try request.code(from: XCTUnwrap(URL(string: "\(base)?error=server_error&state=\(request.state)")))) { error in
            XCTAssertEqual(error as? ApronError, .signInFailed)
        }
    }
}
