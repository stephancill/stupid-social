import NoFeedSocialCore
import SwiftUI

struct FarcasterConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                if viewModel.farcasterStatus == .notConfigured {
                    farcasterUsernameField
                }
                LabeledContent("Connection", value: viewModel.farcasterConnectionLabel)
            }

            if viewModel.farcasterStatus == .notConfigured {
                Section {
                    Button("Save Farcaster Account") {
                        isFocused = false
                        Task { await viewModel.saveFarcasterUsername() }
                    }
                }
            }

            if viewModel.farcasterStatus != .notConfigured {
                Section("Notification Types") {
                    ForEach(FarcasterNotificationCategory.allCases, id: \.self) { category in
                        Toggle(isOn: binding(for: category)) {
                            Text(category.displayLabel)
                        }
                    }
                }

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
        .onAppear { viewModel.message = nil }
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

    private func binding(for category: FarcasterNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.farcasterEnabledCategories.contains(category) },
            set: { viewModel.toggleFarcasterCategory(category, enabled: $0) },
        )
    }
}
