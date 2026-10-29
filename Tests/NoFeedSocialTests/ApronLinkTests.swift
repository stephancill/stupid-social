import Foundation
@testable import NoFeedSocialCore
import XCTest

final class ApronLinkTests: XCTestCase {
    private let server = URL(string: "wss://chat.example/ws")!

    private func link(_ string: String, contentServer: URL? = nil) throws -> ApronLink {
        try ApronLink(url: URL(string: string)!, contentServer: contentServer)
    }

    private func assertFails(_ string: String, with expected: ApronLink.ParseError, contentServer: URL? = nil, line: UInt = #line) {
        XCTAssertThrowsError(try link(string, contentServer: contentServer), line: line) { error in
            XCTAssertEqual(error as? ApronLink.ParseError, expected, line: line)
        }
    }

    func testRecognizesBothForms() throws {
        XCTAssertTrue(try ApronLink.isLink(XCTUnwrap(URL(string: "https://link.apron.chat/#server=wss://chat.example/ws"))))
        XCTAssertTrue(try ApronLink.isLink(XCTUnwrap(URL(string: "apron:?room=ops"))))
        XCTAssertFalse(try ApronLink.isLink(XCTUnwrap(URL(string: "https://link.apron.chat/about"))))
        XCTAssertFalse(try ApronLink.isLink(XCTUnwrap(URL(string: "https://apron.chat/#server=wss://chat.example/ws"))))
    }

    func testParsesWebAndURIForms() throws {
        let web = try link("https://link.apron.chat/#server=wss://chat.example/ws&room=general&message=1724803200042")
        XCTAssertEqual(web, ApronLink(serverURL: server, room: "general", message: "1724803200042"))
        let uri = try link("apron:?server=wss://chat.example/ws&room=general&user=ada")
        XCTAssertEqual(uri, ApronLink(serverURL: server, room: "general", user: "ada"))
    }

    func testFormDecodingAndFirstValueWins() throws {
        let parsed = try link("https://link.apron.chat/#server=wss://chat.example/ws&room=%23ops/alerts&room=other&user=a%2Bb&signal=x")
        XCTAssertEqual(parsed.room, "#ops/alerts")
        XCTAssertEqual(parsed.user, "a+b")
        // A bare `+` decodes to a space, which no ID holds.
        assertFails("apron:?server=wss://chat.example/ws&user=a+b", with: .invalidValue("user"))
    }

    func testWritesWebFormWithEncoding() throws {
        let written = ApronLink(serverURL: server, room: "#ops/a+b&c", message: "42").webURL.absoluteString
        XCTAssertEqual(written, "https://link.apron.chat/#server=wss://chat.example/ws&room=%23ops/a%2Bb%26c&message=42")
        XCTAssertEqual(try ApronLink(url: XCTUnwrap(URL(string: written))).room, "#ops/a+b&c")
        XCTAssertFalse(ApronLink(serverURL: server, token: "secret").webURL.absoluteString.contains("secret"))
    }

    func testRelativeLinksNeedTheContentServer() throws {
        XCTAssertEqual(try link("apron:?room=ops&message=7", contentServer: server), ApronLink(serverURL: server, room: "ops", message: "7"))
        assertFails("apron:?room=ops", with: .missingServer)
        assertFails("https://link.apron.chat/#room=ops&token=abc", with: .missingServer)
    }

    func testServerTransports() throws {
        XCTAssertEqual(try link("apron:?server=ws://localhost:8080/ws&room=agent").serverURL.absoluteString, "ws://localhost:8080/ws")
        XCTAssertNoThrow(try link("apron:?server=ws://127.0.0.1:8080/ws"))
        XCTAssertNoThrow(try link("apron:?server=ws://[::1]:8080/ws"))
        XCTAssertEqual(try link("apron:?server=wss://chat.example").serverURL.absoluteString, "wss://chat.example/")
        assertFails("apron:?server=ws://chat.example/ws", with: .insecureServer)
        assertFails("apron:?server=webrtc:k2Fp9xQ&room=general", with: .unsupportedTransport("webrtc"))
        assertFails("apron:?server=https://chat.example/ws", with: .unsupportedTransport("https"))
        assertFails("apron:?server=wss://user:pass@chat.example/ws", with: .invalidServer)
        assertFails("apron:?server=WSS://chat.example/ws", with: .invalidServer)
    }

    func testValidatesIds() {
        assertFails("apron:?server=wss://chat.example/ws&message=1", with: .invalidValue("message"))
        assertFails("apron:?server=wss://chat.example/ws&room=a&message=01", with: .invalidValue("message"))
        assertFails("apron:?server=wss://chat.example/ws&room=a&message=9007199254740992", with: .invalidValue("message"))
        assertFails("apron:?server=wss://chat.example/ws&room=", with: .invalidValue("room"))
        assertFails("apron:?server=wss://chat.example/ws&user=a%0Ab", with: .invalidValue("user"))
    }

    func testSignInLinks() throws {
        let signIn = try link("https://link.apron.chat/#server=wss://chat.example/ws&token=inv_Qm7x&state=q8Rz")
        XCTAssertEqual(signIn.token, "inv_Qm7x")
        // Its host has already received a token in the query.
        assertFails("https://link.apron.chat/?token=abc#server=wss://chat.example/ws", with: .credentialInQuery)
        // Other keys in the query count after the fragment's.
        let mixed = try link("https://link.apron.chat/?room=fromQuery&user=ada#server=wss://chat.example/ws&room=general")
        XCTAssertEqual(mixed.room, "general")
        XCTAssertEqual(mixed.user, "ada")
    }

    func testHostAndLocality() throws {
        XCTAssertEqual(try link("apron:?server=wss://b%C3%BCcher.example/ws").host, "xn--bcher-kva.example")
        XCTAssertEqual(try link("apron:?server=ws://localhost:8080/ws").host, "localhost:8080")
        XCTAssertTrue(try link("apron:?server=ws://localhost:8080/ws").isLocalServer)
        XCTAssertTrue(try link("apron:?server=wss://192.168.1.4/ws").isLocalServer)
        XCTAssertTrue(try link("apron:?server=wss://pi.local/ws").isLocalServer)
        XCTAssertFalse(try link("apron:?server=wss://chat.example/ws").isLocalServer)
    }

    func testDisplayValueEscapesHiddenCharacters() {
        XCTAssertEqual(ApronLink.displayValue("abc\u{202E}def"), "abc\\u{202E}def")
        XCTAssertEqual(ApronLink.displayValue(String(repeating: "a", count: 60), limit: 11), "aaaaa…aaaaa")
    }

    /// apron-web draws only links read strictly as a place in their own words (docs/behavior.md, "Links as chips").
    func testOnlyStrictPlacesReadAsPlaces() throws {
        let server = try XCTUnwrap(URL(string: "wss://server.apron.chat/"))
        func place(_ link: String) -> ApronLink? {
            ApronLink.place(URL(string: link)!, contentServer: server)
        }
        let message = try XCTUnwrap(place("https://link.apron.chat/#server=wss://server.apron.chat/&room=general&message=1793292155981"))
        XCTAssertEqual(message.room, "general")
        XCTAssertEqual(message.message, "1793292155981")
        XCTAssertEqual(place("https://link.apron.chat/#server=wss://foo.bar.baz/&room=1791590929296")?.host, "foo.bar.baz")
        XCTAssertEqual(place("apron:?room=general")?.serverURL, server, "without a server, the content's")
        XCTAssertEqual(place("https://link.apron.chat/#room=general&user=ada")?.user, "ada")
        for link in [
            "https://link.apron.chat/#weird=foo&token=bar",
            "https://link.apron.chat/#server=wss://server.apron.chat/",
            "https://link.apron.chat/#room=general&room=other",
            "https://link.apron.chat/#room=general&extra=1",
            "https://link.apron.chat/#room=general&message=1&user=ada",
            "https://link.apron.chat/#room=general&message=abc",
            "https://link.apron.chat/#room=",
            "https://link.apron.chat/#room=general&",
            "https://link.apron.chat/?x=1#room=general",
            "https://link.apron.chat/#server=ws://example.com/&room=general",
        ] {
            XCTAssertNil(place(link), link)
        }
    }
}
