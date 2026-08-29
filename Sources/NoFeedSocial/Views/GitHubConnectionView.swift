import NoFeedSocialCore
import SwiftUI

struct GitHubConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            if viewModel.githubStatus == .notConfigured || viewModel.githubStatus == .invalidCredentials {
                Section {
                    Button {
                        showingLoginSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Log in to GitHub", systemImage: "safari")
                            Spacer()
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Connection")
                    Spacer()
                    Text(viewModel.githubConnectionLabel)
                        .foregroundStyle(.secondary)
                }
                if let storage = viewModel.githubCredentialStorage {
                    HStack {
                        Text("Credentials")
                        Spacer()
                        Text(storage.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if devModeEnabled, viewModel.githubStatus == .notConfigured {
                Section("Manual (Dev)") {
                    TextField("Cookie header", text: $viewModel.githubCookieHeader, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                    Button("Save GitHub Credentials") {
                        isFocused = false
                        Task { await viewModel.saveGitHubCookieHeader() }
                    }
                }
            }

            if viewModel.githubStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectGitHub()
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
        .navigationTitle("GitHub")
        .sheet(isPresented: $showingLoginSheet) {
            GitHubLoginWebView { credentials in
                Task { await viewModel.saveGitHubCookies(credentials) }
            }
        }
    }
}
