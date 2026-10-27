import Foundation
import OSLog
import UserNotifications

/// Registers the APNs token with Telegram (token type 1) after sign-in, at launch and when the token changes.
/// Telegram pushes straight to APNs with the certificate uploaded on my.telegram.org, as `loc-key` alerts that
/// `Resources/en.lproj/Localizable.strings` formats; the relay isn't involved.
@MainActor
public final class TelegramPushService {
    private let client: TelegramClient
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "TelegramPush")

    public init(client: TelegramClient) {
        self.client = client
        NotificationCenter.default.addObserver(forName: ApronPushService.deviceTokenDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.register(askingPermission: false) }
            }
        }
    }

    /// Registers when signed in and a token exists. Asks for notification permission first when `askingPermission`,
    /// as right after signing in; at launch it only registers if permission was already given.
    public func register(askingPermission: Bool) async {
        guard await client.account != nil, let token = ApronPushService.storedDeviceToken() else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, askingPermission {
            guard await (try? center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
        } else if settings.authorizationStatus != .authorized, settings.authorizationStatus != .provisional {
            return
        }
        do {
            try await client.registerPush(deviceToken: token, sandbox: ApronPushService.apnsEnvironment == "sandbox")
        } catch {
            logger.error("Telegram push registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
