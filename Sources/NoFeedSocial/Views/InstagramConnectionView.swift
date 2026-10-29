import NoFeedSocialCore
import SwiftUI

/// Adds an Instagram account (`accountId` nil), or shows one account's settings.
struct InstagramConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    private var account: Account? {
        accountId.flatMap(viewModel.account(id:))
    }

    var body: some View {
        Form {
            if let account {
                let categories = viewModel.instagramCategories(account)
                if viewModel.status(for: account.id) == .invalidCredentials {
                    LoginButtonSection(title: "Reconnect Instagram") { showingLoginSheet = true }
                }

                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }

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
                    .disabled(!categories.contains(.directMessages))
                }

                Section("Notification Types") {
                    ForEach(InstagramNotificationCategory.allCases.filter { $0 != .directMessages }, id: \.self) { category in
                        Toggle(category.displayLabel, isOn: binding(category, account: account))
                    }
                }

                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                LoginButtonSection(title: "Log in to Instagram") { showingLoginSheet = true }

                if devModeEnabled {
                    Section("Manual (Dev)") {
                        TextField("Cookie header", text: $viewModel.instagramCookieHeader, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.plain)
                            .focused($isFocused)

                        Button("Save Instagram Credentials") {
                            isFocused = false
                            Task {
                                if await viewModel.addInstagramCookieHeader() != nil {
                                    onDone()
                                }
                            }
                        }
                    }
                }
                MessageSection(message: viewModel.message)
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("Instagram")
        .sheet(isPresented: $showingLoginSheet) {
            InstagramLoginWebView(
                initialCredentials: nil,
                onLoginSuccess: { credentials in
                    Task {
                        let added = await viewModel.addInstagram(credentials, reconnecting: accountId)
                        if added != nil, accountId == nil {
                            onDone()
                        }
                    }
                },
            )
        }
    }

    private func binding(_ category: InstagramNotificationCategory, account: Account) -> Binding<Bool> {
        Binding(
            get: { viewModel.instagramCategories(account).contains(category) },
            set: { viewModel.setInstagramCategory(category, enabled: $0, accountId: account.id) },
        )
    }
}
