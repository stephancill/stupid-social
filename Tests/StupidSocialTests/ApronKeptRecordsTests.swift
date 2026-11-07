import Foundation
@testable import StupidSocialCore
import XCTest

/// Servers without `history` push their log after sign-in; the connection keeps it for chats opened later.
@MainActor
final class ApronKeptRecordsTests: XCTestCase {
    private let serverURL = URL(string: "wss://chat.example/")!

    func testKeptPageHasEachMessagesLatestSnapshotInTheRoom() {
        let connection = ApronConnection(url: serverURL)
        connection.keep(method: "message", params: message(id: "10", log: "10", room: "eng", text: "first"))
        connection.keep(method: "message", params: message(id: "11", log: "11", room: "eng", text: "moved later"))
        connection.keep(method: "message", params: message(id: "12", log: "12", room: "hostel", text: "elsewhere"))
        connection.keep(method: "reactions", params: reactions(message: "10", log: "13", room: "eng"))
        connection.keep(method: "reactions", params: reactions(message: "12", log: "14", room: "hostel"))
        connection.keep(method: "message", params: message(id: "10", log: "15", room: "eng", text: "edited"))
        connection.keep(method: "message", params: message(id: "11", log: "16", room: "tabs", text: "moved later"))
        connection.keep(method: "activity", params: Data(#"{"room_id":"eng"}"#.utf8))

        let page = connection.keptPage(roomId: "eng")

        XCTAssertEqual(page.messages?.map(\.messageId), ["10"])
        XCTAssertEqual(page.messages?.first?.body?.text, "edited")
        XCTAssertEqual(page.reactions?.map(\.messageId), ["10"])
        XCTAssertEqual(page.firstLogId, "13")
        XCTAssertEqual(page.lastLogId, "15")
        XCTAssertEqual(page.more, false)
        XCTAssertEqual(connection.keptPage(roomId: "tabs").messages?.map(\.messageId), ["11"])
    }

    func testKeptRecordsAreCapped() {
        let connection = ApronConnection(url: serverURL)
        for id in 1 ... ApronConnection.keptRecordLimit + 1 {
            connection.keep(method: "message", params: message(id: "\(id)", log: "\(id)", room: "eng", text: "m"))
        }
        let ids = connection.keptPage(roomId: "eng").messages?.compactMap(\.messageId) ?? []
        XCTAssertEqual(ids.count, ApronConnection.keptRecordLimit)
        XCTAssertEqual(ids.first, "2")
    }

    private func message(id: String, log: String, room: String, text: String) -> Data {
        Data(#"{"message_id":"\#(id)","log_id":"\#(log)","room_id":"\#(room)","from":{"user_id":"ada"},"body":{"text":"\#(text)"}}"#.utf8)
    }

    private func reactions(message: String, log: String, room: String) -> Data {
        Data(#"{"message_id":"\#(message)","log_id":"\#(log)","room_id":"\#(room)","reactions":[{"from":{"user_id":"bo"},"emojis":["🐟"]}]}"#.utf8)
    }
}
