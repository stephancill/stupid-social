import Foundation
import os

typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Queues events, persists them across launches, and sends them in batches.
actor Engine {
    struct Configuration {
        var appKey: String
        var endpoint: URL
        /// A new session starts when the app returns after this long in the background.
        var sessionTimeout: TimeInterval = 30 * 60
    }

    static let installIdKey = "net.stupidtech.metrics.installId"

    private let configuration: Configuration
    private let directory: URL
    private let queueURL: URL
    private let diagnosticsDirectory: URL
    private let defaults: UserDefaults
    private let transport: Transport
    private let resolveEnvironment: @Sendable () async -> String
    private let logger = Logger(subsystem: "net.stupidtech.metrics", category: "Engine")

    private var batches: [EventBatch] = []
    private var context: MetricContext
    private var environment: String?
    private(set) var sessionId = UUID().uuidString
    private var backgroundedAt: Date?
    private var isSending = false

    init(
        configuration: Configuration,
        directory: URL,
        defaults: UserDefaults = .standard,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        makeContext: (String) -> MetricContext = { DeviceContext.current(installId: $0) },
        resolveEnvironment: @escaping @Sendable () async -> String = { await DeviceContext.environment() }
    ) {
        self.configuration = configuration
        self.directory = directory
        queueURL = directory.appending(path: "queue.json")
        diagnosticsDirectory = directory.appending(path: "diagnostics", directoryHint: .isDirectory)
        self.defaults = defaults
        self.transport = transport
        self.resolveEnvironment = resolveEnvironment
        let installId = defaults.string(forKey: Self.installIdKey) ?? UUID().uuidString
        defaults.set(installId, forKey: Self.installIdKey)
        context = makeContext(installId)
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = directory
        try? root.setResourceValues(excluded)
        if let data = try? Data(contentsOf: queueURL),
           let saved = try? JSONDecoder().decode([EventBatch].self, from: data)
        {
            batches = saved
        }
    }

    var queuedEventCount: Int {
        batches.reduce(0) { $0 + $1.events.count }
    }

    // MARK: Events

    func enqueue(_ kind: MetricEvent.Kind, name: String, props: [String: String], value: Double?, message: String?, at date: Date) {
        guard Limits.isValidToken(name, maxLength: Limits.maxNameLength) else {
            logger.fault("Dropped metric with invalid name \(name, privacy: .public): use lowercase letters, digits, _ . : -")
            return
        }
        let event = MetricEvent(
            type: kind,
            name: name,
            time: Int64(date.timeIntervalSince1970 * 1000),
            sessionId: sessionId,
            props: Limits.sanitize(props),
            value: value.flatMap { $0.isFinite ? $0 : nil },
            message: message.map { String($0.prefix(Limits.maxMessageLength)) }
        )
        if let last = batches.indices.last, batches[last].context == context {
            batches[last].events.append(event)
        } else {
            batches.append(EventBatch(context: context, events: [event]))
        }
        trimQueue()
        // Errors often precede a crash, so keep them on disk straight away.
        if kind == .error { persist() }
    }

    /// Records `session_start`. At launch the session id from `init` is kept (`renew: false`), so events
    /// enqueued before this call runs still belong to the launch's session.
    func startSession(renew: Bool = true, at date: Date = Date()) {
        if renew { sessionId = UUID().uuidString }
        enqueue(.event, name: "session_start", props: [:], value: nil, message: nil, at: date)
    }

    func didEnterBackground(at date: Date = Date()) {
        backgroundedAt = date
        persist()
    }

    func willEnterForeground(at date: Date = Date()) {
        if let backgroundedAt, date.timeIntervalSince(backgroundedAt) >= configuration.sessionTimeout {
            startSession(at: date)
        }
        backgroundedAt = nil
    }

    private func trimQueue() {
        var overflow = queuedEventCount - Limits.maxQueuedEvents
        while overflow > 0, !batches.isEmpty {
            let dropped = min(overflow, batches[0].events.count)
            batches[0].events.removeFirst(dropped)
            if batches[0].events.isEmpty { batches.removeFirst() }
            overflow -= dropped
        }
    }

    func persist() {
        do {
            if batches.isEmpty {
                try? FileManager.default.removeItem(at: queueURL)
            } else {
                try JSONEncoder().encode(batches).write(to: queueURL, options: .atomic)
            }
        } catch {
            logger.error("Could not save queued metrics: \(ErrorDescription.describe(error), privacy: .public)")
        }
    }

    // MARK: Diagnostics

    /// Saves a MetricKit JSON payload to disk; `flush()` uploads and deletes it.
    func enqueueDiagnostic(kind: String, json: Data) {
        let url = diagnosticsDirectory.appending(path: "\(kind)-\(UUID().uuidString).json")
        do {
            try json.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not save diagnostic: \(ErrorDescription.describe(error), privacy: .public)")
        }
    }

    // MARK: Sending

    /// Sends queued events and diagnostics. Failed requests stay queued for the next flush.
    func flush() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        if environment == nil {
            environment = await resolveEnvironment()
        }
        stampEnvironment()
        dropStaleEvents()

        while let batch = batches.first, !batch.events.isEmpty {
            let chunk = Array(batch.events.prefix(Limits.maxEventsPerRequest))
            let outcome = await send(path: "v1/events", body: try? JSONEncoder().encode(EventBatch(context: batch.context, events: chunk)))
            guard outcome != .retry else { break }
            batches[0].events.removeFirst(chunk.count)
            if batches[0].events.isEmpty { batches.removeFirst() }
        }
        persist()
        await sendDiagnostics()
    }

    private func stampEnvironment() {
        guard let environment else { return }
        if context.environment.isEmpty { context.environment = environment }
        for index in batches.indices where batches[index].context.environment.isEmpty {
            batches[index].context.environment = environment
        }
    }

    private func dropStaleEvents(now: Date = Date()) {
        let cutoff = Int64((now.timeIntervalSince1970 - Limits.maxEventAge) * 1000)
        for index in batches.indices {
            batches[index].events.removeAll { $0.time < cutoff }
        }
        batches.removeAll { $0.events.isEmpty }
    }

    private func sendDiagnostics() async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: nil) else { return }
        guard let contextJSON = try? JSONEncoder().encode(context) else { return }
        for file in files where file.pathExtension == "json" {
            guard let payload = try? Data(contentsOf: file) else { continue }
            let kind = file.lastPathComponent.hasPrefix("metric-") ? "metric" : "diagnostic"
            var body = Data(#"{"kind":"\#(kind)","context":"#.utf8)
            body.append(contextJSON)
            body.append(Data(#","payload":"#.utf8))
            body.append(payload)
            body.append(Data("}".utf8))
            let outcome = await send(path: "v1/diagnostics", body: body)
            if outcome == .retry { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    enum SendOutcome: Equatable {
        case sent
        /// The server refused the data; resending it won't help.
        case rejected
        case retry
    }

    private func send(path: String, body: Data?) async -> SendOutcome {
        guard let body else { return .rejected }
        var request = URLRequest(url: configuration.endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.appKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            let (_, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200 ..< 300:
                return .sent
            case 429, 500...:
                return .retry
            default:
                logger.error("Metrics server rejected \(path, privacy: .public) with \(status)")
                return .rejected
            }
        } catch {
            return .retry
        }
    }

    // MARK: Opt-out

    /// Discards everything queued and the install id, so a later opt-in looks like a new install.
    func reset(makeContext: (String) -> MetricContext = { DeviceContext.current(installId: $0) }) {
        batches = []
        persist()
        try? FileManager.default.removeItem(at: diagnosticsDirectory)
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let installId = UUID().uuidString
        defaults.set(installId, forKey: Self.installIdKey)
        context = makeContext(installId)
        context.environment = environment ?? ""
    }
}
