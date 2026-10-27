import NoFeedSocialCore
import SwiftUI
import UserNotifications

struct DebugConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The app's notifications in Notification Center, as the Notification Service Extension left them.
    @State private var delivered: [DeliveredNotification] = []

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

    private func loadDelivered() async {
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
        details = [
            notification.date.formatted(date: .omitted, time: .standard),
            content.threadIdentifier,
            content.categoryIdentifier,
            content.userInfo["webpush"] == nil ? "rewritten" : "not rewritten",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
