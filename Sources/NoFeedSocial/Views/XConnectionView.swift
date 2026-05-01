import NoFeedSocialCore
import SwiftUI

struct XConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                LabeledContent("Status", value: viewModel.xStatus.label)
            }

            Section {
                Button("Save X Credentials") {
                    isFocused = false
                    Task { await viewModel.saveXCookieHeader() }
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
    }
}
