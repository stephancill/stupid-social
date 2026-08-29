import NoFeedSocialCore
import SwiftUI

struct SpotifyConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            if viewModel.spotifyHandle == nil {
                Section {
                    Button {
                        showingLoginSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Log in to Spotify", systemImage: "safari")
                            Spacer()
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Connection")
                    Spacer()
                    Text(viewModel.spotifyConnectionLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if devModeEnabled, viewModel.spotifyHandle == nil {
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
                        Task { await viewModel.saveSpotifyManualCredentials() }
                    }
                }
            }

            if viewModel.spotifyHandle != nil || viewModel.spotifyStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectSpotify()
                    }
                }
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("Spotify")
        .sheet(isPresented: $showingLoginSheet) {
            SpotifyLoginWebView { credentials in
                Task { await viewModel.saveSpotifyCredentials(credentials) }
            }
        }
    }
}
