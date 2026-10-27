import Foundation
import NoFeedSocialPush
import OSLog
import UserNotifications

/// Registers this device for Apron push on each signed-in connection (§4.9.1). Servers send Web Push to
/// `push.stupidtech.net`, which forwards the ciphertext to APNs; the Notification Service Extension decrypts it
/// with keys only this device holds. Each server can be turned off on this device.
@MainActor
public final class ApronPushService {
    public static let relayURL = URL(string: "https://push.stupidtech.net/register")!
    /// Posted when APNs issues a device token.
    public static let deviceTokenDidChangeNotification = Notification.Name("ApronPushService.deviceTokenDidChange")
    private static let deviceTokenKey = "apronPush.deviceToken"
    private static let disabledServersKey = "apronPush.disabledServers"

    private let store: ApronPushStore
    private let defaults: UserDefaults
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "ApronPush")
    /// The connections registered on, so a device token that arrives later registers them too.
    private var sessions: [URL: ApronSession] = [:]
    /// The last registration started per server. Each waits for the one before, so two at once (a new connection
    /// and a device token arriving) can't both fetch a relay URL and leave the server pushing to both.
    private var registrationTasks: [URL: Task<Void, Never>] = [:]

    public init(store: ApronPushStore = ApronPushStore(), defaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.store = store
        self.defaults = defaults
        self.urlSession = urlSession
        NotificationCenter.default.addObserver(forName: Self.deviceTokenDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions.values where session.connection.isOpen {
                    Task { await self.register(session: session) }
                }
            }
        }
    }

    /// Kept for the next registration; called by the app delegate.
    public static func setDeviceToken(_ token: Data, defaults: UserDefaults = .standard) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard defaults.string(forKey: deviceTokenKey) != hex else { return }
        defaults.set(hex, forKey: deviceTokenKey)
        NotificationCenter.default.post(name: deviceTokenDidChangeNotification, object: nil)
    }

    private var deviceToken: String? {
        defaults.string(forKey: Self.deviceTokenKey)
    }

    /// The APNs token (hex) the app delegate last stored, which Telegram push registers too.
    static func storedDeviceToken(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: deviceTokenKey)
    }

    public func isEnabled(serverURL: URL) -> Bool {
        !(defaults.stringArray(forKey: Self.disabledServersKey) ?? []).contains(serverURL.absoluteString)
    }

    func setEnabled(_ enabled: Bool, serverURL: URL) {
        var disabled = Set(defaults.stringArray(forKey: Self.disabledServersKey) ?? [])
        if enabled {
            disabled.remove(serverURL.absoluteString)
        } else {
            disabled.insert(serverURL.absoluteString)
        }
        defaults.set(disabled.sorted(), forKey: Self.disabledServersKey)
    }

    /// Whether this connection's server pushes to accounts like this one: guests are a new user on each connection.
    public static func offersPush(_ session: ApronSession, isSignedIn: Bool) -> Bool {
        isSignedIn && session.server.push?.webpush != nil
    }

    /// Registers this device with the connection's account, or renews its registration, as clients do on each
    /// connection (§4.9.1). Asks for notification permission the first time.
    func register(session: ApronSession) async {
        sessions[session.serverURL] = session
        let previous = registrationTasks[session.serverURL]
        let registration = Task {
            await previous?.value
            await self.performRegistration(session: session)
        }
        registrationTasks[session.serverURL] = registration
        await registration.value
    }

    private func performRegistration(session: ApronSession) async {
        guard isEnabled(serverURL: session.serverURL), let vapidKey = session.server.push?.webpush?.key else { return }
        guard await isAuthorized() else { return }
        guard let deviceToken else {
            // The token arrives through the app delegate; registration continues then.
            return
        }
        var registrations = store.load()
        var registration = registrations.values.first { $0.serverURL == session.serverURL && $0.userId == session.you.userId }
            ?? ApronPushRegistration(pushId: Self.newPushId(), serverURL: session.serverURL, userId: session.you.userId, keys: .generate())
        do {
            let previousEndpoint = registration.endpoint
            if registration.endpoint == nil || registration.endpointDeviceToken != deviceToken || registration.endpointVapidKey != vapidKey {
                registration.endpoint = try await relayEndpoint(deviceToken: deviceToken, vapidKey: vapidKey)
                registration.endpointDeviceToken = deviceToken
                registration.endpointVapidKey = vapidKey
            }
            guard let endpoint = registration.endpoint else { return }
            if session.server.has("rooms") {
                try await applyRoomTitles(to: &registration, rooms: session.connection.joinedRooms(), you: session.you.userId)
            }
            try await session.connection.registerPush(
                endpoint: endpoint,
                pushId: registration.pushId,
                p256dh: registration.keys.publicKey,
                auth: registration.keys.auth,
                wake: ApronRoomNotifications.registrationWake,
            )
            if let previousEndpoint, previousEndpoint != endpoint {
                try? await session.connection.unregisterPush(endpoint: previousEndpoint)
            }
            registrations[registration.pushId] = registration
            try store.save(registrations)
        } catch {
            logger.info("Apron push registration failed for \(session.serverURL.host() ?? "server", privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unregisters this device from the server on the connection and forgets its keys (§4.9.1).
    func unregister(serverURL: URL, connection: ApronConnection?) async {
        var registrations = store.load()
        let removed = registrations.values.filter { $0.serverURL == serverURL }
        guard !removed.isEmpty else { return }
        for registration in removed {
            if let endpoint = registration.endpoint, let connection, connection.isOpen {
                try? await connection.unregisterPush(endpoint: endpoint)
            }
            registrations[registration.pushId] = nil
        }
        try? store.save(registrations)
    }

    /// Keeps room titles current for notifications, such as after rooms change.
    func updateRoomTitles(session: ApronSession, rooms: (rooms: [ApronRoom], users: [ApronUser])) {
        var registrations = store.load()
        guard var registration = registrations.values.first(where: { $0.serverURL == session.serverURL && $0.userId == session.you.userId }) else { return }
        let before = registration
        applyRoomTitles(to: &registration, rooms: rooms, you: session.you.userId)
        guard registration != before else { return }
        registrations[registration.pushId] = registration
        try? store.save(registrations)
    }

    private func applyRoomTitles(to registration: inout ApronPushRegistration, rooms: (rooms: [ApronRoom], users: [ApronUser]), you: String) {
        let users = Dictionary(rooms.users.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        registration.roomTitles = Dictionary(rooms.rooms.map { ($0.roomId, $0.displayTitle(users: users, you: you)) }, uniquingKeysWith: { first, _ in first })
        registration.directRooms = Set(rooms.rooms.filter(\.isNamedForMembers).map(\.roomId))
        registration.userNames = users.compactMapValues { $0.name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? $0.name : nil }
        // Inline avatars can be large, and the extension has little memory; only linked ones are kept.
        registration.avatarURLs = users.compactMapValues { user in
            user.avatarURL.flatMap { $0.scheme == "https" ? $0 : nil }
        }
    }

    private func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await (try? center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    private func relayEndpoint(deviceToken: String, vapidKey: String) async throws -> URL {
        var request = URLRequest(url: Self.relayURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RelayRegistration(token: deviceToken, environment: Self.apnsEnvironment, vapidKey: vapidKey))
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SourceError.serviceError("The push relay refused the registration (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try JSONDecoder().decode(RelayEndpoint.self, from: data).endpoint
    }

    private static func newPushId() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncodedString
    }

    /// The APNs environment the build's `aps-environment` entitlement selects. Development builds embed it in
    /// their provisioning profile; App Store and TestFlight builds carry none and use production. The simulator
    /// receives pushes through the sandbox.
    static var apnsEnvironment: String {
        #if targetEnvironment(simulator)
            return "sandbox"
        #else
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let profile = try? String(contentsOf: url, encoding: .isoLatin1),
                  let key = profile.range(of: "<key>aps-environment</key>"),
                  let start = profile.range(of: "<string>", range: key.upperBound ..< profile.endIndex),
                  let end = profile.range(of: "</string>", range: start.upperBound ..< profile.endIndex)
            else { return "production" }
            return profile[start.upperBound ..< end.lowerBound] == "production" ? "production" : "sandbox"
        #endif
    }

    private struct RelayRegistration: Encodable {
        let token: String
        let environment: String
        let vapidKey: String
    }

    private struct RelayEndpoint: Decodable {
        let endpoint: URL
    }
}
