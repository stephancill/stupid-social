import Foundation
@testable import StupidSocialCore
import XCTest

/// WhatsApp Web's history sync rule, as Baileys ports it: complete at a RECENT chunk with progress 100, paused when
/// no RECENT chunk comes for two minutes before then.
final class WhatsAppSyncStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testWaitsUntilHistoryArrives() {
        XCTAssertEqual(WhatsAppSyncState().history(at: start), .waiting)
    }

    func testInitialBootstrapStartsSyncingWithoutProgress() {
        var state = WhatsAppSyncState()
        state.received(.initialBootstrap, progress: 0, at: start)
        XCTAssertEqual(state.history(at: start), .syncing(progress: nil))
    }

    func testRecentChunksReportProgressAndCompleteAt100() {
        var state = WhatsAppSyncState()
        state.received(.recent, progress: 45, at: start)
        XCTAssertEqual(state.history(at: start.addingTimeInterval(10)), .syncing(progress: 45))
        state.received(.recent, progress: 100, at: start.addingTimeInterval(20))
        XCTAssertEqual(state.history(at: start.addingTimeInterval(1000)), .complete)
    }

    func testPausesTwoMinutesAfterTheLastChunk() {
        var state = WhatsAppSyncState()
        state.received(.recent, progress: 60, at: start)
        XCTAssertEqual(state.history(at: start.addingTimeInterval(119)), .syncing(progress: 60))
        XCTAssertEqual(state.history(at: start.addingTimeInterval(120)), .paused(progress: 60))
        state.received(.recent, progress: 70, at: start.addingTimeInterval(300))
        XCTAssertEqual(state.history(at: start.addingTimeInterval(301)), .syncing(progress: 70))
    }

    func testOtherSyncTypesLeaveHistoryAlone() {
        var state = WhatsAppSyncState()
        state.received(.pushName, progress: 0, at: start)
        state.received(.onDemand, progress: 0, at: start)
        state.received(.nonBlockingData, progress: 0, at: start)
        XCTAssertEqual(state, WhatsAppSyncState())
    }

    func testDecodesDirectoriesSavedWithoutIt() throws {
        let state = try JSONDecoder().decode(WhatsAppSyncState.self, from: Data("{}".utf8))
        XCTAssertEqual(state, WhatsAppSyncState())
    }

    func testAccountsLinkedBeforeTrackingHideHistory() {
        XCTAssertNil(WhatsAppSyncStatus(state: nil, chatCount: 12).history(at: start))
        XCTAssertEqual(WhatsAppSyncStatus(state: nil, chatCount: 0).history(at: start), .waiting)
    }
}
