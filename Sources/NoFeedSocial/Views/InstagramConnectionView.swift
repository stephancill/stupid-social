import NoFeedSocialCore
import SwiftUI

/// Adds an Instagram account (`accountId` nil), or shows one account's settings.
struct InstagramConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .instagram, accountId: accountId, onDone: onDone) { account in
            Section("Content") {
                Toggle("Stories", isOn: Binding(
                    get: { account.preferences.instagramStoriesEnabled ?? true },
                    set: { viewModel.setInstagramStories(enabled: $0, accountId: account.id) },
                ))
            }

            Section("Messaging") {
                Toggle("Direct Messages", isOn: binding(.directMessages, account: account))
                Toggle("Posts and Reels", isOn: Binding(
                    get: { account.preferences.instagramDirectMediaSharesEnabled ?? true },
                    set: { viewModel.setInstagramDirectMediaShares(enabled: $0, accountId: account.id) },
                ))
                .disabled(!viewModel.instagramCategories(account).contains(.directMessages))
            }

            Section("Notification Types") {
                ForEach(InstagramNotificationCategory.allCases.filter { $0 != .directMessages }, id: \.self) { category in
                    Toggle(category.displayLabel, isOn: binding(category, account: account))
                }
            }
        } manualFields: {
            TextField("Cookie header", text: $viewModel.instagramCookieHeader, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
        } saveManual: {
            await viewModel.addInstagramCookieHeader()
        } login: { complete in
            InstagramLoginWebView(initialCredentials: nil) { credentials in
                complete { await viewModel.addInstagram(credentials, reconnecting: accountId) }
            }
        }
    }

    private func binding(_ category: InstagramNotificationCategory, account: Account) -> Binding<Bool> {
        Binding(
            get: { viewModel.instagramCategories(account).contains(category) },
            set: { viewModel.setInstagramCategory(category, enabled: $0, accountId: account.id) },
        )
    }
}
