import Foundation
@testable import StupidSocialCore
import XCTest

/// `LiveConnection`'s loop with scripted sessions and a recording sleep, so no time passes.
@MainActor
final class LiveConnectionTests: XCTestCase {
    private struct Dropped: Error {}
    private struct Refused: Error {}

    /// Waits recorded by the connection's `sleep`, in seconds.
    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        func record(_ duration: Duration) {
            lock.withLock { values.append(duration / .seconds(1)) }
        }

        var all: [Double] {
            lock.withLock { values }
        }
    }

    /// One scripted attempt: whether it opens, and how it ends.
    private enum Attempt {
        case fail(Error)
        case openThenDrop
        case openThenClose
    }

    /// Runs the attempts in order, then stops the connection and waits for its loop to end.
    private func run(
        _ attempts: [Attempt],
        retry: LiveRetryPolicy = LiveRetryPolicy(jitter: 1 ... 1),
        outcome: @escaping @MainActor (Error) -> LiveOutcome = { _ in .retry },
        observe: ((LiveConnection<Int>) -> Void)? = nil,
    ) async -> (sleeps: [Double], connection: LiveConnection<Int>, attempts: Int) {
        let sleeps = Sleeps()
        var remaining = attempts
        var made = 0
        let finished = expectation(description: "attempts used up")
        finished.assertForOverFulfill = false
        let connection = LiveConnection<Int>(name: "test", retry: retry, outcome: outcome, sleep: { sleeps.record($0) }) { connection in
            guard !remaining.isEmpty else {
                connection.stop()
                finished.fulfill()
                throw CancellationError()
            }
            made += 1
            switch remaining.removeFirst() {
            case let .fail(error):
                throw error
            case .openThenDrop:
                connection.opened()
                connection.deliver(made)
                throw Dropped()
            case .openThenClose:
                connection.opened()
            }
        }
        observe?(connection)
        connection.start()
        await fulfillment(of: [finished], timeout: 2)
        return (sleeps.all, connection, made)
    }

    func testBackoffDoublesAndStartsOverOnceAConnectionOpens() async {
        let result = await run([.fail(Dropped()), .fail(Dropped()), .fail(Dropped()), .openThenDrop, .fail(Dropped())])
        XCTAssertEqual(result.sleeps, [1, 2, 4, 1, 2])
        XCTAssertFalse(result.connection.isOpen)
    }

    func testBackoffIsCappedAndJittered() {
        let policy = LiveRetryPolicy(initial: .seconds(1), maximum: .seconds(60))
        XCTAssertEqual(policy.delay(failures: 3) / .seconds(1), 8)
        XCTAssertEqual(policy.delay(failures: 10) / .seconds(1), 60)
        XCTAssertEqual(policy.delay(failures: 500) / .seconds(1), 60)
    }

    func testCatchUpOnlyAfterAReconnect() async {
        var updates: [String] = []
        _ = await run([.openThenDrop, .openThenClose], observe: { connection in
            _ = connection.observe { update in
                switch update {
                case let .event(value): updates.append("event \(value)")
                case .catchUp: updates.append("catch up")
                }
            }
        })
        XCTAssertEqual(updates, ["event 1", "catch up"])
    }

    func testRemovedObserverHearsNothing() async {
        var heard = 0
        _ = await run([.openThenDrop], observe: { connection in
            let id = connection.observe { _ in heard += 1 }
            connection.removeObserver(id)
        })
        XCTAssertEqual(heard, 0)
    }

    func testStopOutcomeEndsTheLoop() async {
        let sleeps = Sleeps()
        var attempts = 0
        let connection = LiveConnection<Int>(name: "test", outcome: { $0 is Refused ? .stop : .retry }, sleep: { sleeps.record($0) }) { _ in
            attempts += 1
            throw Refused()
        }
        connection.start()
        for _ in 0 ..< 50 where connection.isRunning {
            await Task.yield()
        }
        XCTAssertFalse(connection.isRunning)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps.all, [])
    }

    func testShortConnectionsDontResetAStablePolicy() async {
        let result = await run([.fail(Dropped()), .openThenDrop, .openThenDrop], retry: LiveRetryPolicy(jitter: 1 ... 1, stableAfter: .seconds(120)))
        XCTAssertEqual(result.sleeps, [1, 2, 4])
    }

    func testServerAskedDelayIsTheMinimum() async {
        struct Busy: Error {}
        let result = await run([.fail(Busy()), .fail(Dropped())], outcome: { $0 is Busy ? .retry(minimum: .seconds(30)) : .retry })
        XCTAssertEqual(result.sleeps, [30, 2])
    }

    func testCanConnectGatesStart() {
        var allowed = false
        let connection = LiveConnection<Int>(name: "test", canConnect: { allowed }) { _ in }
        connection.start()
        XCTAssertFalse(connection.isRunning)
        allowed = true
        connection.start()
        XCTAssertTrue(connection.isRunning)
        connection.stop()
        XCTAssertFalse(connection.isRunning)
    }
}
