import Foundation
@testable import NoFeedSocialCore
import XCTest

/// A live delivery updates a room's Chats row from the message alone, without a history page.
@MainActor
final class ApronLiveRowTests: XCTestCase {
    private var source: ApronNotificationSource!
    private var readStore: ApronReadStore!
    private var session: ApronSession!
    private let serverURL = URL(string: "wss://live-row.example/")!

    override func setUp() async throws {
        let suite = "ApronLiveRowTests-\(UUID().uuidString)"
        let accounts = makeTestAccountStore(suite: suite)
        readStore = try ApronReadStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite + ".read")), kvStore: NSUbiquitousKeyValueStore())
        let service = ApronService(accountStore: accounts.store, keychainStore: accounts.keychain, readStore: readStore)
        source = ApronNotificationSource(service: service)
        let info = try JSONDecoder().decode(ApronServerInfo.self, from: Data(#"{"apron":9,"auth":["guest"]}"#.utf8))
        session = ApronSession(
            serverURL: serverURL,
            connection: ApronConnection(url: serverURL),
            server: info,
            you: ApronUser(userId: "me", name: "Me", avatar: nil, roles: nil),
            issuedToken: false,
        )
        readStore.setServerCursor(100, serverURL: serverURL, roomId: "general")
    }

    func testANewMessageFromSomeoneElseIsTheLatestAndUnread() throws {
        let row = try XCTUnwrap(try source.summary(row(unread: 2), adding: message(id: "200", log: "200", from: "ada", text: "hi\nthere"), session: session))
        XCTAssertEqual(row.preview, "Ada: hi there")
        XCTAssertEqual(row.unreadCount, 3)
    }

    func testAMessageBeforeTheReadCursorIsNotUnread() throws {
        let row = try XCTUnwrap(try source.summary(row(unread: 0), adding: message(id: "90", log: "90", from: "ada", text: "old"), session: session))
        XCTAssertEqual(row.unreadCount, 0)
    }

    func testEditsAndDeletionsNeedHistory() throws {
        XCTAssertNil(try source.summary(row(unread: 0), adding: message(id: "200", log: "250", from: "ada", text: "edited"), session: session))
        XCTAssertNil(try source.summary(row(unread: 0), adding: message(id: "200", log: "200", from: "ada", text: "gone", deleted: true), session: session))
    }

    private func row(unread: Int) -> ChatSummary {
        ChatSummary(
            id: "general",
            network: .apron,
            title: "General",
            avatarURL: nil,
            preview: "Ada: before",
            timestamp: Date(timeIntervalSince1970: 0),
            unreadCount: unread,
            destination: .apron(serverURL: serverURL, roomId: "general"),
        )
    }

    private func message(id: String, log: String, from: String, text: String, deleted: Bool = false) throws -> ApronMessage {
        let json = """
        {"message_id":"\(id)","log_id":"\(log)","room_id":"general","from":{"user_id":"\(from)","name":"Ada"},"body":{"text":\(String(data: try JSONEncoder().encode(text), encoding: .utf8)!)},"deleted":\(deleted)}
        """
        return try JSONDecoder().decode(ApronMessage.self, from: Data(json.utf8))
    }
}
