import NoFeedSocialCore
import SwiftUI

struct XConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var xChatViewModel: XChatUnlockViewModel
    @FocusState private var isFocused: Bool
    @State private var confirmingForgetKeys = false
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            if viewModel.xStatus == .notConfigured {
                Section {
                    Button {
                        showingLoginSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Log in to X", systemImage: "safari")
                            Spacer()
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Connection")
                    Spacer()
                    Text(viewModel.xConnectionLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.xStatus != .notConfigured {
                xChatSection
            }

            if viewModel.xStatus != .notConfigured {
                Section("Notifications") {
                    ForEach(XNotificationCategory.allCases, id: \.self) { category in
                        Toggle(category.displayLabel, isOn: binding(for: category))
                    }
                }
            }

            if devModeEnabled, viewModel.xStatus == .notConfigured {
                Section("Manual (Dev)") {
                    TextField("Cookie header", text: $viewModel.xCookieHeader, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)

                    Button("Save X Credentials") {
                        isFocused = false
                        Task { await viewModel.saveXCookieHeader() }
                    }
                }
            }

            if viewModel.xStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectX()
                        xChatViewModel.refresh()
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
        .navigationTitle("X")
        .sheet(isPresented: $showingLoginSheet) {
            XLoginWebView { credentials in
                Task { await viewModel.saveXCookies(credentials) }
            }
        }
    }

    /// X's chats are end-to-end encrypted; the user's X Chat PIN recovers the keys that read them.
    private var xChatSection: some View {
        Section {
            if xChatViewModel.isUnlocked {
                LabeledContent("Encrypted Chats", value: "Unlocked")
                Button("Forget Keys", role: .destructive) {
                    confirmingForgetKeys = true
                }
                .confirmationDialog("Forget X Chat keys?", isPresented: $confirmingForgetKeys, titleVisibility: .visible) {
                    Button("Forget Keys", role: .destructive) {
                        Task { await xChatViewModel.forgetKeys() }
                    }
                } message: {
                    Text("Your X chats stay on X. You'll need your PIN to read them here again.")
                }
            } else {
                SecureField("X Chat PIN", text: $xChatViewModel.pin)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { Task { await xChatViewModel.unlock() } }
                Button {
                    Task { await xChatViewModel.unlock() }
                } label: {
                    if xChatViewModel.isWorking {
                        ProgressView()
                    } else {
                        Text("Unlock Chats")
                    }
                }
                .disabled(!xChatViewModel.canUnlock)
            }
            if let error = xChatViewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Chats")
        } footer: {
            if !xChatViewModel.isUnlocked {
                Text("Your X Chat PIN unlocks your encrypted chats on this Apple account. A wrong PIN uses up one of a limited number of tries.")
            }
        }
    }

    private func binding(for category: XNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.xEnabledCategories.contains(category) },
            set: { enabled in
                viewModel.toggleXCategory(category, enabled: enabled)
            },
        )
    }
}
