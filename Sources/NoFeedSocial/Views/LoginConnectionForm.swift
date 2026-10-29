import NoFeedSocialCore
import SwiftUI
import UIKit

/// The settings of a network that signs in through its login page. Without an account it adds one (`accountId`
/// nil): a login button, and in dev mode credentials entered by hand. With one it shows the account, the
/// network's own `settings`, a reconnect button once its login stops working, and removal.
struct LoginConnectionForm<Settings: View, ManualFields: View, Login: View>: View {
    @ObservedObject var viewModel: SettingsViewModel
    let network: SocialNetwork
    let accountId: String?
    let onDone: () -> Void
    @ViewBuilder let settings: (Account) -> Settings
    /// The dev-mode fields for credentials entered by hand, which `saveManual` adds.
    @ViewBuilder let manualFields: () -> ManualFields
    let saveManual: () async -> Account?
    /// The login page, which hands `complete` the call that adds or reconnects the account.
    @ViewBuilder let login: (_ complete: @escaping (@escaping () async -> Account?) -> Void) -> Login

    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    private var account: Account? {
        accountId.flatMap(viewModel.account(id:))
    }

    var body: some View {
        Form {
            if let account {
                if viewModel.status(for: account.id) == .invalidCredentials {
                    LoginButtonSection(title: "Reconnect \(network.displayName)") { showingLoginSheet = true }
                }
                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }
                settings(account)
                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                LoginButtonSection(title: "Log in to \(network.displayName)") { showingLoginSheet = true }
                if devModeEnabled {
                    Section("Manual (Dev)") {
                        manualFields()
                        Button("Save \(network.displayName) Credentials") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            add(saveManual)
                        }
                    }
                }
                MessageSection(message: viewModel.message)
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle(network.displayName)
        .sheet(isPresented: $showingLoginSheet) {
            login { add($0) }
        }
    }

    /// Adding finishes the Add Account flow; reconnecting stays on the account.
    private func add(_ adding: @escaping () async -> Account?) {
        Task {
            if await adding() != nil, accountId == nil {
                onDone()
            }
        }
    }
}

extension LoginConnectionForm where Settings == EmptyView {
    init(
        viewModel: SettingsViewModel,
        network: SocialNetwork,
        accountId: String?,
        onDone: @escaping () -> Void,
        @ViewBuilder manualFields: @escaping () -> ManualFields,
        saveManual: @escaping () async -> Account?,
        @ViewBuilder login: @escaping (_ complete: @escaping (@escaping () async -> Account?) -> Void) -> Login,
    ) {
        self.init(viewModel: viewModel, network: network, accountId: accountId, onDone: onDone, settings: { _ in EmptyView() }, manualFields: manualFields, saveManual: saveManual, login: login)
    }
}
