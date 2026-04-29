import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("X") {
                    TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                        .lineLimit(3...6)
                    LabeledContent("Status", value: viewModel.xStatus.label)
                    Button("Save X Credentials") {
                        viewModel.saveXCookieHeader()
                    }
                }

                Section("Farcaster") {
                    farcasterUsernameField
                    LabeledContent("Status", value: viewModel.farcasterStatus.label)
                    Button("Save Farcaster Account") {
                        Task { await viewModel.saveFarcasterUsername() }
                    }
                }

                if let message = viewModel.message {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var farcasterUsernameField: some View {
        #if os(iOS)
        TextField("Username", text: $viewModel.farcasterUsername)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField("Username", text: $viewModel.farcasterUsername)
        #endif
    }
}
