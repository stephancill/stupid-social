import NoFeedSocialCore
import SwiftUI

struct InstagramConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Cookie header", text: $viewModel.instagramCookieHeader, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                LabeledContent("Status", value: viewModel.instagramStatus.label)
            }

            Section {
                Button("Save Instagram Credentials") {
                    isFocused = false
                    Task { await viewModel.saveInstagramCookieHeader() }
                }
            }

            if viewModel.instagramStatus != .notConfigured {
                Section("Notification Types") {
                    ForEach(InstagramNotificationCategory.allCases, id: \.self) { category in
                        Toggle(isOn: binding(for: category)) {
                            Text(category.displayLabel)
                        }
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectInstagram()
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
        .navigationTitle("Instagram")
    }

    private func binding(for category: InstagramNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.instagramEnabledCategories.contains(category) },
            set: { viewModel.toggleInstagramCategory(category, enabled: $0) }
        )
    }
}
