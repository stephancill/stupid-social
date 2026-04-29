import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("X") {
                    TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                    LabeledContent("Status", value: viewModel.xStatus.label)
                    Button("Save X Credentials") {
                        isFocused = false
                        viewModel.saveXCookieHeader()
                    }
                }

                Section("Farcaster") {
                    farcasterUsernameField
                    LabeledContent("Status", value: viewModel.farcasterStatus.label)
                    Button("Save Farcaster Account") {
                        isFocused = false
                        Task { await viewModel.saveFarcasterUsername() }
                    }
                }

                if let message = viewModel.message {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("About")) {
                    Button {
                        openURL(URL(string: "https://stupidtech.net")!)
                    } label: {
                        HStack {
                            Text("stupidtech.net")
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        openURL(URL(string: "https://github.com/stephancill/stupid-social")!)
                    } label: {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
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
            .focused($isFocused)
        #else
        TextField("Username", text: $viewModel.farcasterUsername)
            .focused($isFocused)
        #endif
    }
}
