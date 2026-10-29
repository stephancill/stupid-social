import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    var onLoadDemoData: (() -> Void)?
    var onClearDemoData: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @State private var isAddingAccount = false
    @State private var sharesUsageData = AppMetrics.isEnabled

    var body: some View {
        Form {
            Section {
                ForEach(viewModel.accounts) { account in
                    NavigationLink {
                        AccountDetailView(viewModel: viewModel, apronServersViewModel: apronServersViewModel, accountId: account.id)
                    } label: {
                        let label = viewModel.connectionLabel(for: account)
                        AccountRow(
                            network: account.network,
                            subtitle: redacted(label),
                            isInvalid: viewModel.status(for: account.id) == .invalidCredentials,
                            // Only beside a name, not a status such as "Invalid credentials".
                            avatar: account.network == .apron || label != account.label ? nil : AccountAvatar(
                                url: redactionEnabled ? nil : account.avatarURL,
                                name: redacted(label),
                            ),
                        )
                    }
                }

                Button("Add Account") {
                    isAddingAccount = true
                }

                if devModeEnabled {
                    NavigationLink {
                        DebugConnectionView(viewModel: viewModel)
                    } label: {
                        AccountRow(
                            network: .debug,
                            subtitle: viewModel.debugConnectionLabel,
                            isInvalid: viewModel.debugStatus == .invalidCredentials,
                        )
                    }
                }
            } header: {
                Text("Accounts")
            }

            if devModeEnabled {
                Section {
                    Button {
                        onLoadDemoData?()
                    } label: {
                        Text("Load preview content")
                    }
                    Button(role: .destructive) {
                        onClearDemoData?()
                    } label: {
                        Text("Unload preview content")
                    }
                    Toggle("Redact names", isOn: $redactionEnabled)
                } header: {
                    Text("Demo Data")
                } footer: {
                    Text("Preview content uses sample notifications and stories. Unload it to return to your connected accounts.")
                }
            }

            Section {
                Toggle("Share Usage Data", isOn: $sharesUsageData)
                    .onChange(of: sharesUsageData) { _, enabled in
                        AppMetrics.isEnabled = enabled
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Sends anonymous usage counts, errors and crash reports to Stupid Tech to improve the app. Never includes your accounts, messages or notifications.")
            }

            Section {
                Button {
                    openURL(URL(string: "https://stupidtech.net")!)
                } label: {
                    HStack {
                        Text("stupidtech.net")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    openURL(URL(string: "https://github.com/stephancill/stupid-social")!)
                } label: {
                    HStack {
                        Text("GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("About")
                    .onTapGesture(count: 4) {
                        devModeEnabled.toggle()
                    }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            viewModel.loadStatuses()
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountView(viewModel: viewModel, apronServersViewModel: apronServersViewModel)
        }
        .onChange(of: devModeEnabled) { _, enabled in
            if !enabled {
                onClearDemoData?()
            }
        }
    }

    private func redacted(_ subtitle: String) -> String {
        guard redactionEnabled, subtitle.hasPrefix("@") else { return subtitle }
        return "Redacted"
    }
}

struct AccountRow: View {
    let network: SocialNetwork
    let subtitle: String
    var isInvalid = false
    /// Shown before the subtitle when set: the account's own picture, or its initial without one.
    var avatar: AccountAvatar?

    var body: some View {
        HStack {
            if isInvalid {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Invalid credentials")
            }
            Text(network.displayName)
                .font(.body)
            Spacer()
            if let avatar {
                avatar
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// An account's own profile picture, small and round, with its initial while loading or without one.
struct AccountAvatar: View {
    let url: URL?
    let name: String

    var body: some View {
        CachedAsyncImage(url: url) { fallback } failure: { fallback }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var fallback: some View {
        Circle()
            .fill(Color(.tertiarySystemFill))
            .overlay {
                Text(name.trimmingPrefix("@").prefix(1).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Add Account: pick a network, then sign in. The sheet closes once the account is added.
struct AddAccountView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SocialNetwork.addable) { network in
                NavigationLink {
                    addView(for: network)
                } label: {
                    HStack {
                        NetworkBadgeIcon(network: network, size: 22)
                            .accessibilityHidden(true)
                        Text(network.displayName)
                    }
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { viewModel.message = nil }
        }
    }

    @ViewBuilder
    private func addView(for network: SocialNetwork) -> some View {
        let done = { dismiss() }
        switch network {
        case .x: XConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .farcaster: FarcasterConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .instagram: InstagramConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .spotify: SpotifyConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .bluesky: BlueskyConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .github: GitHubConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .telegram: TelegramConnectionView(viewModel: viewModel.makeTelegramSignIn(), onDone: done)
        case .apron: ApronAddServerView(viewModel: apronServersViewModel, onDone: done)
        case .debug: EmptyView()
        }
    }
}

/// One account's settings: its preferences, signing in again, and removing it.
struct AccountDetailView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    let accountId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let account = viewModel.account(id: accountId) {
            detail(for: account)
        } else {
            // Removed here or on another device.
            ContentUnavailableView("Account Removed", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    @ViewBuilder
    private func detail(for account: Account) -> some View {
        let done = { dismiss() }
        switch account.network {
        case .x: XConnectionView(viewModel: viewModel, accountId: account.id, xChatViewModel: viewModel.services.component(id: account.id)?.xChatUnlock, onDone: done)
        case .farcaster: FarcasterConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .instagram: InstagramConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .spotify: SpotifyConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .bluesky: BlueskyConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .github: GitHubConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .telegram:
            if let connection = viewModel.services.component(id: account.id)?.telegramConnection {
                TelegramConnectionView(viewModel: connection, account: account, settings: viewModel, onDone: done)
            }
        case .apron:
            if let serverURL = account.serverURL, let server = apronServersViewModel.server(for: serverURL) {
                ApronServerDetailView(viewModel: apronServersViewModel, server: server)
            }
        case .debug:
            EmptyView()
        }
    }
}

/// The last section of an account's settings: removing it, after a confirmation.
struct RemoveAccountSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let account: Account
    let onRemoved: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Section {
            Button("Remove Account", role: .destructive) {
                isConfirming = true
            }
        }
        .alert("Remove \(account.label ?? account.network.displayName)?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Account", role: .destructive) {
                Task {
                    await viewModel.remove(accountId: account.id)
                    onRemoved()
                }
            }
        } message: {
            Text("This removes the \(account.network.displayName) account and its saved login from this app on all your devices. Nothing changes on \(account.network.displayName).")
        }
    }
}

/// A full-width login button, as at the top of an account's settings.
struct LoginButtonSection: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack {
                    Spacer()
                    Label(title, systemImage: "safari")
                    Spacer()
                }
            }
        }
    }
}

/// The latest result of adding or changing an account.
struct MessageSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
