import NoFeedSocialCore
import SwiftUI

/// Adds an X account (`accountId` nil), or shows one account's settings.
struct XConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    var xChatViewModel: XChatUnlockViewModel?
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    private var account: Account? {
        accountId.flatMap(viewModel.account(id:))
    }

    var body: some View {
        Form {
            if let account {
                if viewModel.status(for: account.id) == .invalidCredentials {
                    LoginButtonSection(title: "Reconnect X") { showingLoginSheet = true }
                }

                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }

                if let xChatViewModel {
                    XChatSection(viewModel: xChatViewModel)
                }

                Section("Notifications") {
                    ForEach(XNotificationCategory.allCases, id: \.self) { category in
                        Toggle(category.displayLabel, isOn: Binding(
                            get: { viewModel.xCategories(account).contains(category) },
                            set: { viewModel.setXCategory(category, enabled: $0, accountId: account.id) },
                        ))
                    }
                }

                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                LoginButtonSection(title: "Log in to X") { showingLoginSheet = true }

                if devModeEnabled {
                    Section("Manual (Dev)") {
                        TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.plain)
                            .focused($isFocused)

                        Button("Save X Credentials") {
                            isFocused = false
                            Task {
                                if await viewModel.addXCookieHeader() != nil {
                                    onDone()
                                }
                            }
                        }
                    }
                }
                MessageSection(message: viewModel.message)
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("X")
        .sheet(isPresented: $showingLoginSheet) {
            XLoginWebView { credentials in
                Task {
                    let added = await viewModel.addX(credentials, reconnecting: accountId)
                    if added != nil, accountId == nil {
                        onDone()
                    }
                }
            }
        }
    }
}

/// X's chats are end-to-end encrypted; the user's X Chat PIN recovers the keys that read them.
private struct XChatSection: View {
    @ObservedObject var viewModel: XChatUnlockViewModel
    @State private var confirmingForgetKeys = false

    var body: some View {
        Section {
            if viewModel.isUnlocked {
                LabeledContent("Encrypted Chats", value: "Unlocked")
                Button("Forget Keys", role: .destructive) {
                    confirmingForgetKeys = true
                }
            } else {
                SecureField("X Chat PIN", text: $viewModel.pin)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { Task { await viewModel.unlock() } }
                Button {
                    Task { await viewModel.unlock() }
                } label: {
                    if viewModel.isWorking {
                        ProgressView()
                    } else {
                        Text("Unlock Chats")
                    }
                }
                .disabled(!viewModel.canUnlock)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Chats")
        } footer: {
            if !viewModel.isUnlocked {
                Text("Your X Chat PIN unlocks this account's encrypted chats on this Apple account. A wrong PIN uses up one of a limited number of tries.")
            }
        }
        .alert("Forget X Chat keys?", isPresented: $confirmingForgetKeys) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Keys", role: .destructive) {
                Task { await viewModel.forgetKeys() }
            }
        } message: {
            Text("Your X chats stay on X. You'll need your PIN to read them here again.")
        }
    }
}
