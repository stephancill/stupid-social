import Foundation
@testable import StupidSocialCore
import XCTest

/// Others' read cursors (§4.6) show the user's messages as sent or seen, on servers that relay them to the room.
@MainActor
final class ApronReadReceiptsTests: XCTestCase {
    private let serverURL = URL(string: "wss://receipts.example/")!

    func testConnectionKeepsEachUsersFurthestCursor() throws {
        let connection = ApronConnection(url: serverURL)
        try connection.applyReadCursor(activity(room: "general", from: "ada", read: "150"))
        try connection.applyReadCursor(activity(room: "general", from: "ada", read: "120"))
        try connection.applyReadCursor(activity(room: "general", from: "bo", read: "90"))
        try connection.applyReadCursor(activity(room: "random", from: "ada", read: "7"))
        XCTAssertEqual(connection.readCursors["general"], ["ada": 150, "bo": 90])
        XCTAssertEqual(connection.readCursors["random"], ["ada": 7])
    }

    func testMessagesUpToOthersCursorAreSeen() throws {
        let adapter = try makeAdapter()
        adapter.restore(snapshot: snapshot(othersRead: "150"))
        let receipts = adapter.messages.map { adapter.receipt(for: $0) }
        XCTAssertEqual(receipts, [.seen, .sent])
    }

    func testNoReceiptsUntilTheServerSharesCursors() throws {
        let adapter = try makeAdapter()
        adapter.restore(snapshot: snapshot(othersRead: nil))
        XCTAssertEqual(adapter.messages.map { adapter.receipt(for: $0) }, [nil, nil])
    }

    private func makeAdapter() throws -> ApronChatAdapter {
        let suite = "ApronReadReceiptsTests-\(UUID().uuidString)"
        let accounts = makeTestAccountStore(suite: suite)
        let readStore = try ApronReadStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite + ".read")), kvStore: NSUbiquitousKeyValueStore())
        let service = ApronService(accountStore: accounts.store, keychainStore: accounts.keychain, readStore: readStore)
        return ApronChatAdapter(service: service, serverURL: serverURL, roomId: "general", title: "General")
    }

    private func activity(room: String, from: String, read: String) throws -> ApronActivity {
        let json = #"{"room_id":"\#(room)","from":{"user_id":"\#(from)"},"read_message_id":"\#(read)"}"#
        return try JSONDecoder().decode(ApronActivity.self, from: Data(json.utf8))
    }

    private func snapshot(othersRead: String?) -> Data {
        let messages = ["100", "200"].map { id in
            #"{"message_id":"\#(id)","log_id":"\#(id)","room_id":"general","from":{"user_id":"me","name":"Me"},"body":{"text":"hi"}}"#
        }
        let read = othersRead.map { #","othersRead":\#($0)"# } ?? ""
        return Data(#"{"messages":[\#(messages.joined(separator: ","))],"users":[],"reactions":[],"mediaOrigins":[]\#(read)}"#.utf8)
    }
}
