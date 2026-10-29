import NoFeedSocialCore
import SwiftUI

/// Adds a GitHub account (`accountId` nil), or shows one account's settings.
struct GitHubConnectionView: View {
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
                if viewModel.status(for: account.id) == .invalidCredentials {
                    LoginButtonSection(title: "Reconnect GitHub") { showingLoginSheet = true }
                }
                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }
                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                LoginButtonSection(title: "Log in to GitHub") { showingLoginSheet = true }

                if devModeEnabled {
                    Section("Manual (Dev)") {
                        TextField("Cookie header", text: $viewModel.githubCookieHeader, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                        Button("Save GitHub Credentials") {
                            isFocused = false
                            Task {
                                if await viewModel.addGitHubCookieHeader() != nil {
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
        .navigationTitle("GitHub")
        .sheet(isPresented: $showingLoginSheet) {
            GitHubLoginWebView { credentials in
                Task {
                    let added = await viewModel.addGitHub(credentials, reconnecting: accountId)
                    if added != nil, accountId == nil {
                        onDone()
                    }
                }
            }
        }
    }
}
