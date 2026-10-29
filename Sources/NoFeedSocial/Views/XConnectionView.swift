import NoFeedSocialCore
import SwiftUI

/// Adds an X account (`accountId` nil), or shows one account's settings.
struct XConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    var xChatViewModel: XChatUnlockViewModel?
    let onDone: () -> Void

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .x, accountId: accountId, onDone: onDone) { account in
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
        } manualFields: {
            TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
        } saveManual: {
            await viewModel.addXCookieHeader()
        } login: { complete in
            XLoginWebView { credentials in
                complete { await viewModel.addX(credentials, reconnecting: accountId) }
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
