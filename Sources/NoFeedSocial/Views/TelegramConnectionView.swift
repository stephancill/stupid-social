import NoFeedSocialCore
import SwiftUI

/// Signs in to Telegram with a phone number, the code Telegram sends, and the 2FA password if there is one.
/// Without `account` it adds an account; with one it signs that account in or out on this device, since each
/// device is its own Telegram session.
struct TelegramConnectionView: View {
    @ObservedObject var viewModel: TelegramConnectionViewModel
    var account: Account?
    var settings: SettingsViewModel?
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            if let account, let settings {
                Section {
                    LabeledContent("Account", value: settings.connectionLabel(for: account))
                } footer: {
                    if case .signedIn = viewModel.step {
                        EmptyView()
                    } else {
                        Text("This account was added on another device. Sign in to use it here too.")
                    }
                }
            }
            if !viewModel.isAvailable {
                Section {
                    Text("Telegram isn't available in this build.")
                        .foregroundStyle(.secondary)
                }
            } else {
                switch viewModel.step {
                case .phone:
                    Section {
                        TextField("Phone number", text: $viewModel.phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($isFocused)
                        Button("Send Code") {
                            Task { await viewModel.sendCode() }
                        }
                        .disabled(viewModel.isWorking || viewModel.phone.isEmpty)
                    } footer: {
                        Text("Include the country code, such as +1. Chats appear on the Chats screen; channels and archived chats aren't shown.")
                    }
                case let .code(sentTo):
                    Section {
                        TextField("Code", text: $viewModel.code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($isFocused)
                        Button("Sign In") {
                            Task { await viewModel.signIn() }
                        }
                        .disabled(viewModel.isWorking || viewModel.code.isEmpty)
                        Button("Use a Different Number") {
                            viewModel.startOver()
                        }
                    } footer: {
                        Text(sentTo)
                    }
                case let .password(hint):
                    Section {
                        SecureField("Password", text: $viewModel.password)
                            .textContentType(.password)
                            .focused($isFocused)
                        Button("Sign In") {
                            Task { await viewModel.checkPassword() }
                        }
                        .disabled(viewModel.isWorking || viewModel.password.isEmpty)
                        Button("Start Over") {
                            viewModel.startOver()
                        }
                    } header: {
                        Text("Two-Step Verification")
                    } footer: {
                        if let hint, !hint.isEmpty {
                            Text("Hint: \(hint)")
                        }
                    }
                case let .signedIn(account):
                    Section {
                        LabeledContent("Account", value: account.name)
                        if let username = account.username {
                            LabeledContent("Username", value: "@\(username)")
                        }
                    }
                    if account != nil {
                        Section {
                            Button("Sign Out on This Device", role: .destructive) {
                                confirmingSignOut = true
                            }
                        }
                    }
                }

                if viewModel.isWorking {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let account, let settings {
                RemoveAccountSection(viewModel: settings, account: account, onRemoved: onDone)
            }
        }
        .navigationTitle("Telegram")
        .task { await viewModel.reload() }
        .onChange(of: viewModel.step) { _, step in
            if case .signedIn = step, account == nil {
                onDone()
                return
            }
            isFocused = true
        }
        .alert("Sign out of Telegram on this device?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await viewModel.signOut() }
            }
        } message: {
            Text("This device's Telegram session ends. The account stays on your other devices, and your chats stay on Telegram.")
        }
    }
}
