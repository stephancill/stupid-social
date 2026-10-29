import Foundation
import os
#if canImport(UIKit)
    import UIKit
#endif

/// Anonymous usage events, error reports and MetricKit diagnostics for Stupid Tech apps.
///
/// Call ``configure(appKey:endpoint:)`` once at launch, then ``track(_:properties:value:)``
/// and ``error(_:error:properties:)`` from anywhere. Names and property keys use
/// lowercase letters, digits and `_ . : -`; values are short, low-cardinality strings.
/// Never pass user content, names, handles, URLs or tokens.
public enum StupidMetrics {
    public static let defaultEndpoint = URL(string: "https://metrics.stupidtech.net")!

    static let disabledKey = "net.stupidtech.metrics.disabled"
    /// Long enough that a batch merges many events into few rollup writes on the server.
    private static let flushInterval: Duration = .seconds(5 * 60)
    private static let state = OSAllocatedUnfairLock<Engine?>(initialState: nil)
    private static let logger = Logger(subsystem: "net.stupidtech.metrics", category: "StupidMetrics")

    /// Whether metrics are collected and sent. Persists across launches; turning it
    /// off discards anything queued and the anonymous install id.
    public static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set {
            let wasEnabled = isEnabled
            UserDefaults.standard.set(!newValue, forKey: disabledKey)
            guard let engine = state.withLock({ $0 }), wasEnabled != newValue else { return }
            Task {
                if newValue {
                    await engine.startSession()
                } else {
                    await engine.reset()
                }
            }
        }
    }

    /// Starts collection: a `session_start` event now and whenever the app returns
    /// after 30 minutes away, batched sends every 5 minutes and on backgrounding,
    /// and MetricKit crash, hang and exit reports.
    @MainActor
    public static func configure(appKey: String, endpoint: URL = defaultEndpoint) {
        guard state.withLock({ $0 }) == nil else {
            logger.fault("StupidMetrics.configure called more than once")
            return
        }
        let directory = URL.applicationSupportDirectory.appending(path: "StupidMetrics", directoryHint: .isDirectory)
        let engine = Engine(configuration: .init(appKey: appKey, endpoint: endpoint), directory: directory)
        state.withLock { $0 = engine }

        if isEnabled {
            Task { await engine.startSession(renew: false) }
        }
        Task {
            while true {
                try? await Task.sleep(for: flushInterval)
                if isEnabled { await engine.flush() }
            }
        }
        observeLifecycle(engine)
        MetricKitSubscriber.start(engine: engine)
    }

    /// Records a usage event, e.g. `track("refresh", properties: ["network": "x"], value: 812)`.
    public static func track(_ name: String, properties: [String: String] = [:], value: Double? = nil) {
        record(.event, name: name, properties: properties, value: value, message: nil)
    }

    /// Records an error with a developer-written message. Errors with the same name,
    /// message and properties are grouped into one issue on the dashboard.
    public static func error(_ name: String, message: String? = nil, properties: [String: String] = [:]) {
        record(.error, name: name, properties: properties, value: nil, message: message)
    }

    /// Records an error described only by its type and case (see ``describe(_:)``).
    public static func error(_ name: String, error: any Error, properties: [String: String] = [:]) {
        record(.error, name: name, properties: properties, value: nil, message: describe(error))
    }

    /// An error's type and case without its payload or localized text, e.g.
    /// `URLError.-1009` or `DecodingError.keyNotFound`.
    public static func describe(_ error: any Error) -> String {
        ErrorDescription.describe(error)
    }

    /// Sends everything queued now.
    public static func flush() async {
        guard isEnabled, let engine = state.withLock({ $0 }) else { return }
        await engine.flush()
    }

    private static func record(_ kind: MetricEvent.Kind, name: String, properties: [String: String], value: Double?, message: String?) {
        guard isEnabled else { return }
        guard let engine = state.withLock({ $0 }) else {
            logger.fault("StupidMetrics used before configure(); dropped \(name, privacy: .public)")
            return
        }
        let date = Date()
        Task { await engine.enqueue(kind, name: name, props: properties, value: value, message: message, at: date) }
    }

    @MainActor
    private static func observeLifecycle(_ engine: Engine) {
        #if canImport(UIKit) && !os(watchOS)
            let center = NotificationCenter.default
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                let date = Date()
                // Keeps the process alive long enough to save and send the queue.
                ProcessInfo.processInfo.performExpiringActivity(withReason: "Send metrics") { expired in
                    guard !expired else { return }
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        await engine.didEnterBackground(at: date)
                        if isEnabled { await engine.flush() }
                        done.signal()
                    }
                    _ = done.wait(timeout: .now() + 20)
                }
            }
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                let date = Date()
                Task {
                    guard isEnabled else { return }
                    await engine.willEnterForeground(at: date)
                }
            }
        #endif
    }
}
