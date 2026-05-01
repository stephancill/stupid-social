import NoFeedSocialCore
import SwiftUI

struct DebugConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                TextField("http://127.0.0.1:8787", text: $viewModel.debugServerURL)
                    .autocorrectionDisabled()

                Button("Save") {
                    viewModel.saveDebugServerURL()
                }
            } footer: {
                Text("Use this only for local testing. Background refresh will fetch /notifications from this server.")
            }

            Section("Status") {
                Text(viewModel.debugStatus.label)
                if let message = viewModel.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Debug")
    }
}
