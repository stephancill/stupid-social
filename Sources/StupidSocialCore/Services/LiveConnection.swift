import Foundation
import OSLog

/// Something an account keeps open while the app is in the foreground, such as a network's event stream.
@MainActor
public protocol LiveConnecting: AnyObject {
    func start()
    func stop()
}

/// What observers of a `LiveConnection` receive.
public enum LiveUpdate<Event> {
    case event(Event)
    /// Events may have been missed, so fetch what's new: a connection opened after an earlier one closed, or the
    /// network asked for it.
    case catchUp
}

/// How a `LiveConnection` waits between attempts: exponential backoff with jitter.
public struct LiveRetryPolicy: Sendable {
    public var initial: Duration
    public var maximum: Duration
    /// Each delay is scaled by a random factor in this range, so clients don't reconnect in step.
    public var jitter: ClosedRange<Double>
    /// How long a connection must stay up before the delay starts over; `nil` starts over as soon as one opens.
    public var stableAfter: Duration?

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(60), jitter: ClosedRange<Double> = 0.5 ... 1.5, stableAfter: Duration? = nil) {
        self.initial = initial
        self.maximum = maximum
        self.jitter = jitter
        self.stableAfter = stableAfter
    }

    /// The delay after `failures` failed attempts in a row, before jitter.
    func delay(failures: Int) -> Duration {
        let seconds = initial / .seconds(1) * pow(2, Double(min(failures, 30)))
        return min(.seconds(seconds), maximum)
    }
}

/// What a closed connection's error means for reconnecting.
public enum LiveOutcome: Sendable {
    /// Reconnect after the backoff, and not sooner than `minimum`, such as a delay the server asked for.
    case retry(minimum: Duration)
    /// Don't reconnect until `start()` is called again, such as after credentials were refused.
    case stop

    public static let retry = LiveOutcome.retry(minimum: .zero)
}

/// One network connection kept open while the app is in the foreground, shared by everything that follows it
/// (the Chats list and every open chat of the account). It owns the parts every network repeats: starting and
/// stopping, reconnecting with backoff, observers, and telling them to catch up after a reconnect. The network
/// supplies only `session`, which opens one connection, calls `opened()` once it is up, `deliver(_:)`s its
/// events, and returns or throws when it closes.
@MainActor
public final class LiveConnection<Event>: LiveConnecting {
    public typealias Session = @MainActor (LiveConnection<Event>) async throws -> Void

    public let name: String
    private let retry: LiveRetryPolicy
    private let canConnect: @MainActor () -> Bool
    private let outcome: @MainActor (Error) -> LiveOutcome
    private let session: Session
    private let sleep: @Sendable (Duration) async -> Void
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "LiveConnection")

    private var loop: Task<Void, Never>?
    private var observers: [UUID: (LiveUpdate<Event>) -> Void] = [:]
    private var hasConnected = false
    private var openedAt: ContinuousClock.Instant?

    /// Whether a connection is up now.
    public private(set) var isOpen = false

    /// - Parameters:
    ///   - canConnect: checked before each attempt, such as whether the account still has keys.
    ///   - outcome: what an error a session throws means; every error retries by default.
    ///   - sleep: waits between attempts; tests replace it.
    public init(
        name: String,
        retry: LiveRetryPolicy = LiveRetryPolicy(),
        canConnect: @escaping @MainActor () -> Bool = { true },
        outcome: @escaping @MainActor (Error) -> LiveOutcome = { _ in .retry },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        session: @escaping Session,
    ) {
        self.name = name
        self.retry = retry
        self.canConnect = canConnect
        self.outcome = outcome
        self.sleep = sleep
        self.session = session
    }

    public var isRunning: Bool {
        loop != nil
    }

    public func start() {
        guard loop == nil, !DemoData.isDemoMode, canConnect() else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        isOpen = false
    }

    public func observe(_ handler: @escaping (LiveUpdate<Event>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: For sessions

    /// The connection is up. After an earlier connection, observers are told to catch up.
    public func opened() {
        isOpen = true
        openedAt = .now
        if hasConnected {
            notify(.catchUp)
        }
        hasConnected = true
    }

    public func deliver(_ event: Event) {
        notify(.event(event))
    }

    /// The network says events were missed, such as X's pull instruction.
    public func requestCatchUp() {
        notify(.catchUp)
    }

    private func notify(_ update: LiveUpdate<Event>) {
        for observer in Array(observers.values) {
            observer(update)
        }
    }

    // MARK: Loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled, canConnect() {
            openedAt = nil
            var closing: Error?
            do {
                try await session(self)
            } catch {
                closing = error
            }
            isOpen = false
            guard !Task.isCancelled else { return }
            if let openedAt, retry.stableAfter.map({ ContinuousClock.now - openedAt >= $0 }) ?? true {
                failures = 0
            }
            var minimum = Duration.zero
            if let closing {
                switch outcome(closing) {
                case .stop:
                    logger.info("\(name, privacy: .public) stopped: \(closing.localizedDescription, privacy: .public)")
                    loop = nil
                    return
                case let .retry(asked):
                    minimum = asked
                    logger.info("\(name, privacy: .public) closed: \(closing.localizedDescription, privacy: .public)")
                }
            }
            let backoff = retry.delay(failures: failures) * Double.random(in: retry.jitter)
            failures += 1
            await sleep(max(backoff, minimum))
        }
        if !Task.isCancelled {
            loop = nil
        }
    }
}
