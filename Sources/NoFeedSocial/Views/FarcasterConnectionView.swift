import NoFeedSocialCore
import SwiftUI

struct FarcasterConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @AppStorage("FarcasterBaseURL") private var farcasterBaseURL: String = ""

    var body: some View {
        Form {
            Section {
                farcasterUsernameField
                LabeledContent("Status", value: viewModel.farcasterStatus.label)
            }

            Section {
                #if os(iOS)
                TextField("Server URL (optional)", text: $farcasterBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                #else
                TextField("Server URL (optional)", text: $farcasterBaseURL)
                    .focused($isFocused)
                #endif
            } footer: {
                Text("Override the Farcaster API server. Leave empty for default.")
            }

            Section {
                Button("Save Farcaster Account") {
                    isFocused = false
                    Task { await viewModel.saveFarcasterUsername() }
                }
            }

            if viewModel.farcasterStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectFarcaster()
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
        .navigationTitle("Farcaster")
    }

    @ViewBuilder
    private var farcasterUsernameField: some View {
        #if os(iOS)
        TextField("Username", text: $viewModel.farcasterUsername)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
        #else
        TextField("Username", text: $viewModel.farcasterUsername)
            .focused($isFocused)
        #endif
    }
}
