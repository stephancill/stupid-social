import NoFeedSocialCore
import SwiftUI

/// Adds a Farcaster account by username (`accountId` nil), or shows one account's settings.
struct FarcasterConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @AppStorage(FarcasterExternalClient.storageKey) private var externalClient = FarcasterExternalClient.defaultClient

    private var account: Account? {
        accountId.flatMap(viewModel.account(id:))
    }

    var body: some View {
        Form {
            if let account {
                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }

                Section("Notification Types") {
                    ForEach(FarcasterNotificationCategory.allCases, id: \.self) { category in
                        Toggle(category.displayLabel, isOn: Binding(
                            get: { viewModel.farcasterCategories(account).contains(category) },
                            set: { viewModel.setFarcasterCategory(category, enabled: $0, accountId: account.id) },
                        ))
                    }
                }

                Section {
                    NavigationLink {
                        FarcasterExternalClientView()
                    } label: {
                        LabeledContent("External Client", value: externalClient.displayName)
                    }
                }

                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                Section {
                    TextField("Username", text: $viewModel.farcasterUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                    Button("Add Account") {
                        isFocused = false
                        Task {
                            if await viewModel.addFarcaster() != nil {
                                onDone()
                            }
                        }
                    }
                    .disabled(viewModel.isWorking || viewModel.farcasterUsername.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                MessageSection(message: viewModel.message)
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("Farcaster")
    }
}
