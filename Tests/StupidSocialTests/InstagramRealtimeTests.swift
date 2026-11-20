import Foundation
@testable import StupidSocialCore
import XCTest

final class InstagramRealtimeTests: XCTestCase {
    func testDGWFramesRoundTripAndCarryAckIds() throws {
        let body = Data(#"{"request_id":1}"#.utf8)
        let message = InstagramDGW.frame(InstagramDGW.establishStream, Data("{}".utf8)) + InstagramDGW.dataFrame(body) + Data([InstagramDGW.pong])
        // The web client's opening bytes for the same frames (observed 2026-11-20).
        XCTAssertEqual([UInt8](message.prefix(8)), [0x0F, 0x00, 0x00, 0x02, 0x00, 0x00, 0x7B, 0x7D])
        let frames = InstagramDGW.frames(message)
        XCTAssertEqual(frames.map(\.kind), [InstagramDGW.establishStream, InstagramDGW.data, InstagramDGW.pong])
        let split = try XCTUnwrap(InstagramDGW.split(dataPayload: frames[1].payload))
        XCTAssertEqual(split.id, 0)
        XCTAssertTrue(split.wantsAck)
        XCTAssertEqual(split.body, body)
        // The server's second push asks for an ack of id 1, which the client sends back as `0c 0000 020000 0100`.
        XCTAssertEqual(InstagramDGW.split(dataPayload: Data([0x01, 0x80]))?.id, 1)
        XCTAssertEqual([UInt8](InstagramDGW.ackFrame(id: 1)), [0x0C, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual(InstagramDGW.frames(Data([0x0D, 0x00, 0x00, 0x09, 0x00, 0x00, 0x01])), [], "A truncated frame is dropped")
    }

    func testSyncPayloadDecodesPushedMessages() throws {
        let results = #"""
        [{"data":{"slide_delta_processor":[{"__typename":"SlideUQPPNewMessage","uq_seq_id":"6476","thread_read_state_effect":"MARK_READ","thread_fbid":"555","message":{"thread_fbid":"555","message_id":"mid.$abc","id":"mid.$abc","sender_fbid":"100","text_body":"hello","timestamp_ms":"1795132393860","content_type":"TEXT","content":{"__typename":"SlideMessageText","text_body":"hello"},"reactions":[],"sender":{"id":"7","name":"Friend","user_dict":{"username":"friend"}}}},{"__typename":"SlideUQPPReaction","thread_fbid":"556"}]}}]
        """#
        let entry = Self.field(1, varint: 223) + Self.field(2, bytes: Data(results.utf8)) + Self.field(3, varint: 6476)
        let payload = Self.field(1, bytes: Data([6, 0])) + Self.field(2, bytes: Self.field(3, bytes: entry))
        let (deltas, seqId) = InstagramDirectSync.deltas(fromPayload: payload)
        XCTAssertEqual(seqId, 6476)
        XCTAssertEqual(deltas.map(\.typename), ["SlideUQPPNewMessage", "SlideUQPPReaction"])
        XCTAssertEqual(deltas.map(\.threadFbid), ["555", "556"])
        let message = try XCTUnwrap(deltas.first?.message)
        XCTAssertEqual(message.id, "mid.$abc")
        XCTAssertEqual(message.textBody, "hello")
        XCTAssertEqual(message.senderFbid, "100")

        // The answer to the sync request: field 2 { 1 { 1: database, 2, 3: seq id } }, no deltas.
        let answer = Self.field(1, bytes: Data([6, 0])) + Self.field(2, bytes: Self.field(1, bytes: Self.field(1, varint: 223) + Self.field(2, varint: 6475) + Self.field(3, varint: 6475)))
        XCTAssertEqual(InstagramDirectSync.deltas(fromPayload: answer).deltas.count, 0)
    }

    @MainActor
    func testConnectionStopsWhenSignedOutAndWaitsOutARateLimit() {
        if case .stop = InstagramLiveFeed.outcome(for: SourceError.notConfigured) {} else { XCTFail("A signed-out session stops") }
        guard case let .retry(minimum) = InstagramLiveFeed.outcome(for: SourceError.rateLimited(until: Date().addingTimeInterval(300))) else {
            return XCTFail("A rate limit retries")
        }
        XCTAssertGreaterThan(minimum, .seconds(290))
        if case let .retry(minimum) = InstagramLiveFeed.outcome(for: URLError(.networkConnectionLost)) {
            XCTAssertEqual(minimum, .zero)
        } else {
            XCTFail("A dropped connection retries")
        }
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }

    private static func field(_ number: UInt64, varint value: UInt64) -> Data {
        varint(number << 3) + varint(value)
    }

    private static func field(_ number: UInt64, bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }
}
