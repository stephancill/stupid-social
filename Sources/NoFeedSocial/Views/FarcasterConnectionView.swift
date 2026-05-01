import NoFeedSocialCore
import SwiftUI

struct FarcasterConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                farcasterUsernameField
                LabeledContent("Status", value: viewModel.farcasterStatus.label)
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
