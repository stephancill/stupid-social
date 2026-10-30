import CryptoKit
import Foundation
import NoFeedSocialPush
import OSLog
import UserNotifications

/// Delivers a reminder set on one of the user's devices to the others when it's due, even when their app isn't
/// running: the device that sets it encrypts it to each other device and leaves the pushes with
/// `push.stupidtech.net`, which sends them at the due time.
///
/// Every device signs with one VAPID key kept in the iCloud Keychain, so any device can schedule pushes to, and
/// cancel those of, the others. Each device registers a relay endpoint for that key with its own Web Push keys
/// (`ChatReminderPushStore`, which the extension decrypts with) and publishes them in iCloud KVS under its own
/// key, `com.stupid.chatreminders.device.<device id>`, so devices never overwrite each other's entries.
@MainActor
public enum ChatReminderPush {
    /// A device as the others see it in iCloud KVS.
    struct Device: Codable, Equatable {
        let deviceId: String
        /// The relay endpoint's id, the last path component of its URL.
        let endpoint: String
        let p256dh: String
        let auth: String
        let vapidKey: String
        let updatedAt: Double
    }

    public enum PushError: Error {
        case payloadTooLarge
        case relayRefused(status: Int)
    }

    static let relayOrigin = URL(string: "https://push.stupidtech.net")!
    private static let devicePrefix = "com.stupid.chatreminders.device."
    /// A device that hasn't refreshed its entry for this long is taken to be gone.
    private static let deviceLifetime: TimeInterval = 60 * 24 * 60 * 60
    private static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    /// The relay's limit for a push's plaintext (§4.9.3).
    private static let maxPayloadBytes = 2048
    /// Message text in a push is cut to this, so the reminder fits the payload.
    private static let maxTextBytes = 600

    private static let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "ChatReminderPush")
    private static let keychain = KeychainCredentialStore()
    private static let store = ChatReminderPushStore()
    private static var kvStore: NSUbiquitousKeyValueStore = .default
    private static var tokenObserver: NSObjectProtocol?
    private static var registration: Task<Void, Never>?

    /// Registers this device now and again whenever the APNs token changes. Called once at launch.
    static func start(kvStore: NSUbiquitousKeyValueStore) {
        guard tokenObserver == nil else { return }
        self.kvStore = kvStore
        tokenObserver = NotificationCenter.default.addObserver(forName: ApronPushService.deviceTokenDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { register() }
        }
        register()
    }

    /// This device's id, once it has registered.
    static var deviceId: String? {
        store.load()?.deviceId
    }

    /// Creates or renews this device's endpoint and publishes it, without asking for notification permission.
    /// Registrations run one after another, so two can't both fetch an endpoint.
    static func register() {
        let previous = registration
        registration = Task {
            await previous?.value
            do {
                try await performRegistration()
            } catch {
                logger.info("Chat reminder push registration failed: \(String(describing: error), privacy: .public)")
                AppMetrics.chatReminderPushFailed(step: "register", error: error)
            }
        }
    }

    private static func performRegistration() async throws {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status),
              let deviceToken = ApronPushService.storedDeviceToken()
        else { return }
        let vapidKey = try signingKey().publicKey.x963Representation.base64URLEncodedString
        var registration = store.load() ?? ChatReminderPushRegistration(deviceId: UUID().uuidString, keys: .generate())
        if registration.endpoint == nil || registration.endpointDeviceToken != deviceToken || registration.endpointVapidKey != vapidKey {
            registration.endpoint = try await relayEndpoint(deviceToken: deviceToken, vapidKey: vapidKey)
            registration.endpointDeviceToken = deviceToken
            registration.endpointVapidKey = vapidKey
            try store.save(registration)
        }
        guard let endpoint = registration.endpoint else { return }
        let key = devicePrefix + registration.deviceId
        let published = kvStore.data(forKey: key).flatMap { try? JSONDecoder().decode(Device.self, from: $0) }
        let device = try Device(
            deviceId: registration.deviceId,
            endpoint: endpoint.lastPathComponent,
            p256dh: registration.keys.publicKey.base64URLEncodedString,
            auth: registration.keys.auth.base64URLEncodedString,
            vapidKey: vapidKey,
            updatedAt: Date().timeIntervalSince1970,
        )
        let isCurrent = published.map {
            $0.endpoint == device.endpoint && $0.p256dh == device.p256dh && $0.vapidKey == device.vapidKey
                && device.updatedAt - $0.updatedAt < refreshInterval
        } ?? false
        guard !isCurrent else { return }
        try kvStore.set(JSONEncoder().encode(device), forKey: key)
        kvStore.synchronize()
    }

    /// The user's other devices that can receive a push signed with this device's key.
    private static func otherDevices(vapidKey: String) -> [Device] {
        let ownId = deviceId
        let cutoff = Date().timeIntervalSince1970 - deviceLifetime
        return kvStore.dictionaryRepresentation
            .filter { $0.key.hasPrefix(devicePrefix) }
            .compactMap { ($0.value as? Data).flatMap { try? JSONDecoder().decode(Device.self, from: $0) } }
            .filter { $0.deviceId != ownId && $0.vapidKey == vapidKey && $0.updatedAt > cutoff }
            .sorted { $0.deviceId < $1.deviceId }
    }

    /// Leaves the reminder's pushes to the other devices with the relay, and returns the ids of the devices it
    /// will reach; empty when there are none.
    static func schedule(_ reminder: ChatReminder) async throws -> [String] {
        let key = try signingKey()
        let vapidKey = key.publicKey.x963Representation.base64URLEncodedString
        let devices = otherDevices(vapidKey: vapidKey)
        guard !devices.isEmpty else { return [] }

        let payload = try JSONEncoder().encode(reminder.truncatedForPush(maxTextBytes: maxTextBytes))
        guard payload.count <= maxPayloadBytes else { throw PushError.payloadTooLarge }
        let pushes = try devices.map { device in
            guard let p256dh = Data(base64URLEncoded: device.p256dh), let auth = Data(base64URLEncoded: device.auth) else {
                throw WebPushError.malformed
            }
            let ciphertext = try WebPushEncryptor.encrypt(payload, publicKey: p256dh, auth: auth)
            return ScheduledPush(endpoint: device.endpoint, payload: ciphertext.base64URLEncodedString)
        }
        let body = Schedule(
            deliverAt: Int(reminder.dueDate.timeIntervalSince1970.rounded(.up)),
            // Shown only when the extension can't read the push.
            alert: .init(title: "Reminder", body: "A chat reminder is due"),
            pushes: pushes,
        )
        try await send(method: "PUT", name: reminder.id, body: JSONEncoder().encode(body), key: key)
        return devices.map(\.deviceId)
    }

    /// Cancels the reminder's pushes to the other devices.
    static func cancel(reminderId: String) async throws {
        try await send(method: "DELETE", name: reminderId, body: nil, key: signingKey())
    }

    private static func send(method: String, name: String, body: Data?, key: P256.Signing.PrivateKey) async throws {
        var request = URLRequest(url: relayOrigin.appending(path: "scheduled/\(name)"))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try request.setValue(vapidAuthorization(key: key), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw PushError.relayRefused(status: status) }
    }

    private static func relayEndpoint(deviceToken: String, vapidKey: String) async throws -> URL {
        var request = URLRequest(url: ApronPushService.relayURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": deviceToken, "environment": ApronPushService.apnsEnvironment, "vapidKey": vapidKey])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PushError.relayRefused(status: status) }
        struct Endpoint: Decodable { let endpoint: URL }
        return try JSONDecoder().decode(Endpoint.self, from: data).endpoint
    }

    /// The VAPID key every device of the user shares, created by the first device that needs it. Two devices
    /// creating one before the Keychain syncs settle on whichever the Keychain keeps, and re-register then.
    private static func signingKey() throws -> P256.Signing.PrivateKey {
        if let data = keychain.loadChatReminderPushKey(), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try keychain.saveChatReminderPushKey(key.rawRepresentation)
        return key
    }

    /// A `vapid` Authorization (RFC 8292) for the relay, valid for 12 hours.
    static func vapidAuthorization(key: P256.Signing.PrivateKey, now: Date = Date()) throws -> String {
        let header = try JSONEncoder().encode(["typ": "JWT", "alg": "ES256"]).base64URLEncodedString
        let claims = try JSONSerialization.data(withJSONObject: [
            "aud": relayOrigin.absoluteString,
            "exp": Int(now.timeIntervalSince1970) + 12 * 60 * 60,
            "sub": "https://stupidtech.net",
        ], options: [.sortedKeys]).base64URLEncodedString
        let input = "\(header).\(claims)"
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation.base64URLEncodedString
        return "vapid t=\(input).\(signature), k=\(key.publicKey.x963Representation.base64URLEncodedString)"
    }

    private struct Schedule: Encodable {
        struct Alert: Encodable {
            let title: String
            let body: String
        }

        let deliverAt: Int
        let alert: Alert
        let pushes: [ScheduledPush]
    }

    private struct ScheduledPush: Encodable {
        let endpoint: String
        let payload: String
    }
}
