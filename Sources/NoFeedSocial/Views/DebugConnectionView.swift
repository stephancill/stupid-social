import NoFeedSocialCore
import NoFeedSocialPush
import SwiftUI
import UserNotifications

struct DebugConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The app's notifications in Notification Center, as the Notification Service Extension left them.
    @State private var delivered: [DeliveredNotification] = []
    @State private var extensionLog: [PushExtensionLog.Entry] = []
    @State private var telegramAvatarUserIds: [Int64] = []

    var body: some View {
        Form {
            Section {
                TextField("http://127.0.0.1:8787", text: $viewModel.debugServerURL)
                    .autocorrectionDisabled()

                Button("Save") {
                    viewModel.saveDebugServerURL()
                }
            } footer: {
                Text("Use this only for local testing. Background refresh will fetch /notifications from this server.")
            }

            if viewModel.debugStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectDebug()
                    }
                }
            }

            Section {
                ForEach(delivered) { notification in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notification.title).font(.headline)
                        if !notification.subtitle.isEmpty {
                            Text(notification.subtitle).font(.subheadline)
                        }
                        Text(notification.body)
                        Text(notification.details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            } header: {
                Text("Delivered Notifications")
            } footer: {
                Text(delivered.isEmpty ? "None in Notification Center." : "Newest first, as the notification extension left them.")
            }

            Section {
                ForEach(extensionLog, id: \.self) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.network) \(entry.chat)")
                        Text(Self.outcome(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
                Button("Post Test Telegram Notification") {
                    Task { await postTestTelegramNotification() }
                }
                .disabled(telegramAvatarUserIds.isEmpty)
            } header: {
                Text("Notification Extension")
            } footer: {
                Text((extensionLog.isEmpty ? "No runs recorded. " : "Newest first. ") + "\(telegramAvatarUserIds.count) Telegram avatars saved for notifications. The test posts a local notification from one of those users through the extension's code, in 3 seconds.")
            }

            Section("Status") {
                Text(viewModel.debugStatus.label)
                if let message = viewModel.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { viewModel.message = nil }
        .task { await loadDelivered() }
        .refreshable { await loadDelivered() }
        .navigationTitle("Debug")
    }

    /// A message from a user whose avatar is saved, made as the extension makes one, so the avatar can be checked
    /// without a push.
    private func postTestTelegramNotification() async {
        guard let userId = telegramAvatarUserIds.first else { return }
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "MESSAGE_TEXT", "loc-args": ["Test Sender", "Debug notification"]]],
            "custom": ["from_id": String(userId)],
        ]
        guard let telegram = TelegramPushNotification.make(userInfo: userInfo, localized: { _, _ in nil }) else { return }
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        content.sound = .default
        telegram.prepare(content)
        nonisolated(unsafe) let prepared = content
        let communication = await CommunicationNotification.telegram(telegram, content: prepared) ?? prepared
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: communication,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false),
        )
        try? await UNUserNotificationCenter.current().add(request)
        extensionLog = PushExtensionLog().load()
    }

    private static func outcome(_ entry: PushExtensionLog.Entry) -> String {
        [
            entry.date.formatted(date: .omitted, time: .standard),
            entry.hasAvatar ? "avatar" : "no avatar",
            entry.donateError.map { "donate failed: \($0)" } ?? "donated",
            entry.updateError.map { "update failed: \($0)" } ?? "updated",
        ].joined(separator: " · ")
    }

    private func loadDelivered() async {
        extensionLog = PushExtensionLog().load()
        telegramAvatarUserIds = TelegramAvatarStore().userIds
        delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            .sorted { $0.date > $1.date }
            .map(DeliveredNotification.init)
    }
}

private struct DeliveredNotification: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let details: String

    init(_ notification: UNNotification) {
        let content = notification.request.content
        id = notification.request.identifier
        title = content.title
        subtitle = content.subtitle
        body = content.body
        let rewritten = if AppDelegate.telegramPeer(content.userInfo) != nil {
            content.threadIdentifier.hasPrefix("telegram|") ? "rewritten" : "not rewritten"
        } else {
            content.userInfo["webpush"] == nil ? "rewritten" : "not rewritten"
        }
        details = [
            notification.date.formatted(date: .omitted, time: .standard),
            content.threadIdentifier,
            content.categoryIdentifier,
            rewritten,
            Self.payloadShape(content.userInfo),
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// For Telegram pushes, whose format isn't documented for APNs: the keys and `loc-key`, never text.
    private static func payloadShape(_ userInfo: [AnyHashable: Any]) -> String {
        guard AppDelegate.telegramPeer(userInfo) != nil else { return "" }
        let aps = userInfo["aps"] as? [String: Any] ?? [:]
        let alert = aps["alert"]
        let alertShape = if let alert = alert as? [String: Any] {
            "alert{\(alert.keys.sorted().joined(separator: ","))}" + ((alert["loc-key"] as? String).map { " \($0)" } ?? "")
        } else {
            alert is String ? "alert(text)" : "no alert"
        }
        let custom = (userInfo["custom"] as? [String: Any]).map { "custom{\($0.keys.sorted().joined(separator: ","))}" } ?? "no custom"
        return [
            "keys{\(userInfo.keys.compactMap { $0 as? String }.sorted().joined(separator: ","))}",
            "aps{\(aps.keys.sorted().joined(separator: ","))}",
            alertShape,
            custom,
        ].joined(separator: " · ")
    }
}
