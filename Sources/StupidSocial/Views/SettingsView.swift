import StupidSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    var onLoadDemoData: (() -> Void)?
    var onClearDemoData: (() -> Void)?
    /// Command-line chat access; only when the app runs on a Mac.
    var chatControlServer: ChatControlServer?
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @AppStorage("demoModeEnabled") private var demoModeEnabled = false
    @State private var isAddingAccount = false
    @State private var sharesUsageData = AppMetrics.isEnabled
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section {
                // While any account needs reconnecting, only those show here; the rest are a push away.
                let invalidAccounts = viewModel.accounts.filter { viewModel.status(for: $0.id) == .invalidCredentials }
                ForEach(invalidAccounts.isEmpty ? viewModel.accounts : invalidAccounts) { account in
                    SettingsAccountLink(viewModel: viewModel, apronServersViewModel: apronServersViewModel, account: account)
                }

                if !invalidAccounts.isEmpty {
                    NavigationLink {
                        AllAccountsView(viewModel: viewModel, apronServersViewModel: apronServersViewModel)
                    } label: {
                        HStack {
                            Text("All Accounts")
                            Spacer()
                            // Each network with a connected account, once, in account order.
                            let connected = viewModel.accounts
                                .filter { viewModel.status(for: $0.id) != .invalidCredentials }
                                .map(\.network)
                                .reduce(into: [SocialNetwork]()) { if !$0.contains($1) { $0.append($1) } }
                            NetworkBadgeStack(networks: connected)
                        }
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
                    Toggle("Preview content", isOn: Binding(
                        get: { demoModeEnabled },
                        set: { $0 ? onLoadDemoData?() : onClearDemoData?() },
                    ))
                    Toggle("Redact names", isOn: $redactionEnabled)
                } header: {
                    Text("Demo Data")
                } footer: {
                    Text("Preview content shows sample notifications, stories and chats in place of your connected accounts.")
                }
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

            // Advanced is a group of sections: the first carries the header, styled like the page's other section
            // titles with a Mail-style disclosure chevron, and the rest show only while it's expanded.
            Section {
                if showsAdvanced {
                    Toggle("Share Usage Data", isOn: $sharesUsageData)
                        .onChange(of: sharesUsageData) { _, enabled in
                            AppMetrics.isEnabled = enabled
                        }
                }
            } header: {
                Button {
                    withAnimation(.snappy) { showsAdvanced.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Advanced")
                        Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } footer: {
                if showsAdvanced {
                    Text("Sends anonymous usage counts, errors and crash reports to Stupid Tech to improve the app. Never includes your accounts, messages or notifications.")
                }
            }

            if showsAdvanced {
                ChatStorageSection()

                if let chatControlServer {
                    ChatControlSection(server: chatControlServer)
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
}

/// Up to five network badges overlapping, each ringed in the row's colour, then "+N" for the rest.
private struct NetworkBadgeStack: View {
    let networks: [SocialNetwork]
    private let limit = 5
    private let size: CGFloat = 20

    var body: some View {
        HStack(spacing: -size / 3) {
            ForEach(networks.prefix(limit), id: \.self) { network in
                ringed(NetworkBadgeIcon(network: network, size: size))
            }
            if networks.count > limit {
                ringed(
                    Text("+\(networks.count - limit)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: size, height: size)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous)),
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(networks.map(\.displayName).formatted(.list(type: .and)))
    }

    private func ringed(_ badge: some View) -> some View {
        badge
            .padding(1.5)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: size / 4 + 1.5, style: .continuous))
    }
}

/// Every account, from Settings while some need reconnecting and the Accounts section shows only those.
private struct AllAccountsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    @State private var query = ""
    @State private var selectedNetworks: Set<SocialNetwork> = []

    /// Each network with an account, once, in account order.
    private var networks: [SocialNetwork] {
        viewModel.accounts.map(\.network).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Accounts on a selected network (any, with none selected) whose network, name or status contains the query.
    private var accounts: [Account] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return viewModel.accounts.filter { account in
            (selectedNetworks.isEmpty || selectedNetworks.contains(account.network))
                && (query.isEmpty || [account.network.displayName, viewModel.name(for: account), viewModel.connectionLabel(for: account)]
                    .contains { $0.localizedStandardContains(query) })
        }
    }

    var body: some View {
        Form {
            if networks.count > 1 {
                // A header rather than a row, as in Search: out by the header's inset, so the pills scroll to the
                // screen's edges and line up with the search field.
                Section {} header: {
                    NetworkFilterBar(networks: networks, selection: $selectedNetworks)
                        .textCase(nil)
                        .padding(.horizontal, -16)
                }
                .listSectionSpacing(.compact)
            }
            Section {
                ForEach(accounts) { account in
                    SettingsAccountLink(viewModel: viewModel, apronServersViewModel: apronServersViewModel, account: account)
                }
            }
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Accounts")
    }
}

/// An account's row in Settings, pushing its detail.
private struct SettingsAccountLink: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var apronServersViewModel: ApronServersViewModel
    let account: Account
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        NavigationLink {
            AccountDetailView(viewModel: viewModel, apronServersViewModel: apronServersViewModel, accountId: account.id)
        } label: {
            let label = viewModel.connectionLabel(for: account)
            // Only beside a name, not a status such as "Invalid credentials"; an Apron server only with its own icon.
            let showsAvatar = account.network == .apron
                ? viewModel.status(for: account.id) != .invalidCredentials && viewModel.rowAvatarURL(for: account) != nil
                : label == account.label
            AccountRow(
                network: account.network,
                subtitle: redacted(label),
                isInvalid: viewModel.status(for: account.id) == .invalidCredentials,
                avatar: showsAvatar ? AccountAvatar(
                    url: redactionEnabled ? nil : viewModel.rowAvatarURL(for: account),
                    name: redacted(label),
                ) : nil,
            )
        }
    }

    private func redacted(_ subtitle: String) -> String {
        guard redactionEnabled, subtitle.hasPrefix("@") else { return subtitle }
        return "Redacted"
    }
}

/// Turns on the `stupid-social` command line and shows the token it pairs with.
private struct ChatControlSection: View {
    @ObservedObject var server: ChatControlServer
    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            Toggle("Command-Line Access", isOn: $server.isEnabled)
            if server.isEnabled {
                LabeledContent("Token") {
                    Text(server.token)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Copy Pairing Command") {
                    UIPasteboard.general.string = "stupid-social pair \(server.token)"
                }
                Button("Reset Token", role: .destructive) {
                    isConfirmingReset = true
                }
                .confirmationDialog("Reset the token?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                    Button("Reset Token", role: .destructive) {
                        server.resetToken()
                    }
                } message: {
                    Text("The command line stops working until you pair it again.")
                }
            }
        } footer: {
            if let error = server.error {
                Text(error)
                    .foregroundStyle(.red)
            } else {
                Text("Lets the stupid-social command read and send your chats while the app is open, on port \(String(ChatControlServer.port)) of this Mac. Anything with the token can act as you.")
            }
        }
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
    @State private var query = ""

    private var networks: [SocialNetwork] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SocialNetwork.addable }
        return SocialNetwork.addable.filter { $0.displayName.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(networks) { network in
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
            .overlay {
                if networks.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
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
        case .discord: DiscordConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .linkedin: LinkedInConnectionView(viewModel: viewModel, accountId: nil, onDone: done)
        case .telegram: TelegramAddAccountView(settings: viewModel, onDone: done)
        case .whatsapp: WhatsAppAddAccountView(settings: viewModel, onDone: done)
        case .apron: ApronAddServerView(viewModel: apronServersViewModel, onDone: done)
        case .debug: EmptyView()
        }
    }
}

/// Adding a Telegram account. The sign-in is a state object so the phone number, the step and the client
/// waiting for its code survive the view updating, such as when the app goes to the background and back.
private struct TelegramAddAccountView: View {
    @StateObject private var connection: TelegramConnectionViewModel
    let onDone: () -> Void

    init(settings: SettingsViewModel, onDone: @escaping () -> Void) {
        _connection = StateObject(wrappedValue: settings.makeTelegramSignIn())
        self.onDone = onDone
    }

    var body: some View {
        TelegramConnectionView(viewModel: connection, onDone: onDone)
    }
}

/// Adding a WhatsApp account. The link is a state object so the QR code or pairing code and the connection
/// waiting on it survive the view updating, such as while the user switches to WhatsApp to enter the code.
private struct WhatsAppAddAccountView: View {
    @StateObject private var connection: WhatsAppConnectionViewModel
    let onDone: () -> Void

    init(settings: SettingsViewModel, onDone: @escaping () -> Void) {
        _connection = StateObject(wrappedValue: settings.makeWhatsAppLink())
        self.onDone = onDone
    }

    var body: some View {
        WhatsAppConnectionView(viewModel: connection, onDone: onDone)
    }
}

/// Linking an existing WhatsApp account on this device again.
private struct WhatsAppRelinkView: View {
    @StateObject private var connection: WhatsAppConnectionViewModel
    @ObservedObject var settings: SettingsViewModel
    let account: Account
    let onDone: () -> Void

    init(settings: SettingsViewModel, account: Account, onDone: @escaping () -> Void) {
        _connection = StateObject(wrappedValue: settings.makeWhatsAppLink(accountId: account.id))
        self.settings = settings
        self.account = account
        self.onDone = onDone
    }

    var body: some View {
        WhatsAppConnectionView(viewModel: connection, account: account, settings: settings, isLinked: settings.isWhatsAppLinked(accountId: account.id), onDone: onDone)
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
        case .discord: DiscordConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .linkedin: LinkedInConnectionView(viewModel: viewModel, accountId: account.id, onDone: done)
        case .telegram:
            if let connection = viewModel.services.component(id: account.id)?.telegramConnection {
                TelegramConnectionView(viewModel: connection, account: account, settings: viewModel, onDone: done)
            }
        case .whatsapp:
            WhatsAppRelinkView(settings: viewModel, account: account, onDone: done)
        case .apron:
            if let serverURL = account.serverURL, let server = apronServersViewModel.server(for: serverURL) {
                ApronServerDetailView(viewModel: apronServersViewModel, server: server)
            }
        case .debug:
            EmptyView()
        }
    }
}

/// How much space chats' history takes on this device, and clearing it, after a confirmation. Chats load from the
/// networks again when opened or loaded ahead. One of Settings' Advanced sections.
private struct ChatStorageSection: View {
    @State private var size = ChatKit.store.size
    @State private var isConfirming = false
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Chat History", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            Button("Clear Chat History", role: .destructive) {
                isConfirming = true
            }
        } footer: {
            if let error {
                Text(error)
            }
        }
        .onAppear {
            size = ChatKit.store.size
        }
        .alert("Clear chat history?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat History", role: .destructive) {
                do {
                    try ChatKit.store.removeHistory()
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                size = ChatKit.store.size
            }
        } message: {
            Text("Chats load from their networks again. Nothing changes on the networks.")
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
