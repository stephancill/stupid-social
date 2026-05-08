import NoFeedSocialCore
import SwiftUI

struct XConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingLoginSheet = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Log in to X", systemImage: "safari")
                        Spacer()
                    }
                }
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(viewModel.xStatus.label)
                        .foregroundStyle(.secondary)
                }
            }

            if devModeEnabled {
                Section("Manual (Dev)") {
                    TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)

                    Button("Save X Credentials") {
                        isFocused = false
                        Task { await viewModel.saveXCookieHeader() }
                    }
                }
            }

            if viewModel.xStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectX()
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
        .navigationTitle("X")
        .sheet(isPresented: $showingLoginSheet) {
            XLoginWebView { credentials in
                Task { await viewModel.saveXCookies(credentials) }
            }
        }
    }
}
