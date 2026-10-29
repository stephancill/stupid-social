import NoFeedSocialCore
import SwiftUI

/// Adds a Spotify account (`accountId` nil), or shows one account's settings.
struct SpotifyConnectionView: View {
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
                    LoginButtonSection(title: "Reconnect Spotify") { showingLoginSheet = true }
                }
                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }
                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                LoginButtonSection(title: "Log in to Spotify") { showingLoginSheet = true }

                if devModeEnabled {
                    Section("Manual (Dev)") {
                        TextField("Bearer token", text: $viewModel.spotifyBearerToken, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.plain)
                            .focused($isFocused)
                        TextField("Client token", text: $viewModel.spotifyClientToken, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.plain)
                        TextField("sp_dc cookie", text: $viewModel.spotifySpDC, axis: .vertical)
                            .lineLimit(1 ... 2)
                            .textFieldStyle(.plain)
                        Button("Save Spotify Credentials") {
                            isFocused = false
                            Task {
                                if await viewModel.addSpotifyManualCredentials() != nil {
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
        .navigationTitle("Spotify")
        .sheet(isPresented: $showingLoginSheet) {
            SpotifyLoginWebView { credentials in
                Task {
                    let added = await viewModel.addSpotify(credentials, reconnecting: accountId)
                    if added != nil, accountId == nil {
                        onDone()
                    }
                }
            }
        }
    }
}
