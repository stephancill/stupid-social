import NoFeedSocialCore
import SwiftUI

/// Every chat across networks, newest first; the page to the left of the feed.
struct ChatsView: View {
    @ObservedObject var viewModel: ChatListViewModel
    let apronService: ApronService
    /// The chat for a Spotify account's chat id and title; `nil` when the account is gone.
    let spotifyChat: (_ accountId: String, _ chatId: String, _ title: String) -> (() -> ChatViewModel)?
    /// The chat for an Instagram account's thread and title; `nil` when the account is gone.
    let instagramChat: (_ accountId: String, _ threadFbid: String, _ title: String) -> (() -> ChatViewModel)?
    /// The chat for a Telegram account's peer; `nil` when the account is gone.
    let telegramChat: (_ accountId: String, _ peer: TelegramPeer, _ title: String, _ userStatus: ChatPresence?) -> (chat: () -> ChatViewModel, members: () -> TelegramMembersViewModel)?
    /// The chat for an X account's conversation and title; `nil` until its X Chat PIN unlocks it.
    let xChat: (_ accountId: String, _ conversationId: String, _ title: String) -> (() -> ChatViewModel)?
    /// Whether a chat is pushed, so the home pager can stop paging.
    @Binding var isShowingChat: Bool
    /// A chat to open, such as from a tapped notification; cleared once opened.
    @Binding var openRequest: ChatSummary.Destination?
    @State private var selection: ChatSummary?
    /// A requested chat the list doesn't have yet, such as a Telegram chat from a notification at launch; it
    /// opens once a load lists it.
    @State private var waitingRequest: ChatSummary.Destination?
    /// What a link asked to show in the chat it opened.
    @State private var focus: (destination: ChatSummary.Destination, focus: NotificationRouter.ChatFocus)?
    @State private var isShowingArchive = false
    @State private var query = ""
    /// With the search bar in the navigation bar's drawer, rows present while the bar first lays out start the
    /// list collapsed to the inline title, so saved chats are inserted just after the screen appears.
    @State private var hasAppeared = false

    var body: some View {
        List {
            // Like Telegram, archived chats sit behind one row at the top, which search looks through.
            if hasAppeared, query.isEmpty, !viewModel.archivedChats.isEmpty {
                Button {
                    isShowingArchive = true
                } label: {
                    ArchivedChatsRow(chats: viewModel.archivedChats)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden, edges: .top)
                .compactListRowInsets()
            }
            ForEach(filteredChats) { chat in
                Button {
                    selection = chat
                } label: {
                    ChatRow(chat: chat)
                }
                .buttonStyle(.plain)
                // Only the line above the first row; lower rows share theirs with the row above.
                .listRowSeparator(chat.id == filteredChats.first?.id && !showsArchiveRow ? .hidden : .automatic, edges: .top)
                .compactListRowInsets()
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredChats.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if viewModel.chats.isEmpty {
                if viewModel.hasLoaded {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right", description: Text("Chats from Apron servers, Spotify, Instagram, Telegram and X appear here."))
                } else {
                    ProgressView()
                }
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            hasAppeared = true
        }
        .navigationTitle("Chats")
        .toolbar {
            if !viewModel.connections.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ConnectionStatusButton(viewModel: viewModel)
                }
            }
        }
        .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: selection == nil && !isShowingArchive) { _, isOnList in
            isShowingChat = !isOnList
            if isOnList {
                focus = nil
            }
        }
        .navigationDestination(item: $selection) { chat in
            destination(for: chat)
        }
        .navigationDestination(isPresented: $isShowingArchive) {
            ArchivedChatsView(viewModel: viewModel) { AnyView(destination(for: $0)) }
        }
        .onChange(of: openRequest, initial: true) { _, request in
            guard let request else { return }
            openRequest = nil
            focus = NotificationRouter.shared.pendingFocus.map { (request, $0) }
            NotificationRouter.shared.pendingFocus = nil
            guard selection?.destination != request else { return }
            guard let chat = chat(for: request) else {
                waitingRequest = request
                return
            }
            waitingRequest = nil
            open(chat)
        }
        .onChange(of: viewModel.chats + viewModel.archivedChats) { _, _ in
            guard let request = waitingRequest, let chat = chat(for: request) else { return }
            waitingRequest = nil
            open(chat)
        }
        // Reloads on returning from a chat too, so unread counts and latest messages stay current.
        .task(id: selection == nil) {
            guard selection == nil else { return }
            await viewModel.load()
        }
    }

    private func open(_ chat: ChatSummary) {
        guard selection != nil else {
            selection = chat
            return
        }
        // A destination that is showing isn't replaced when its item changes, so close it, then open the chat.
        selection = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            selection = chat
        }
    }

    private var showsArchiveRow: Bool {
        hasAppeared && query.isEmpty && !viewModel.archivedChats.isEmpty
    }

    /// Chats whose name or latest message contains the query, archived ones included.
    private var filteredChats: [ChatSummary] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard hasAppeared else { return [] }
        guard !query.isEmpty else { return viewModel.chats }
        return (viewModel.chats + viewModel.archivedChats).filter { chat in
            chat.title.localizedStandardContains(query) || (chat.preview ?? "").localizedStandardContains(query)
        }
    }

    /// The listed chat, or one titled by its room until the list has it.
    private func chat(for destination: ChatSummary.Destination) -> ChatSummary? {
        if let listed = (viewModel.chats + viewModel.archivedChats).first(where: { $0.destination == destination }) {
            return listed
        }
        // A Telegram notification names the chat without its access hash, so it matches on kind and id.
        if case let .telegram(peer) = destination {
            return (viewModel.chats + viewModel.archivedChats).first { chat in
                guard case let .telegram(listed) = chat.destination else { return false }
                return listed.kind == peer.kind && listed.id == peer.id
            }
        }
        guard case let .apron(serverURL, roomId) = destination else { return nil }
        return ChatSummary(
            id: "apron:\(serverURL.absoluteString)|\(roomId)",
            network: .apron,
            title: roomId,
            subtitle: serverURL.host(),
            avatarURL: nil,
            preview: nil,
            timestamp: nil,
            unreadCount: 0,
            destination: destination,
        ).scoped(to: Account.apronId(serverURL: serverURL))
    }

    /// A network chat opening from its row, which says whether there are unread messages to wait for.
    private func opened<ViewModel: ChatViewModel>(_ chatViewModel: ViewModel, chat: ChatSummary) -> ViewModel {
        if chat.unreadCount > 0 {
            chatViewModel.expectUnread()
        }
        return viewModel.follow(chatViewModel, chatId: chat.id)
    }

    @ViewBuilder
    private func destination(for chat: ChatSummary) -> some View {
        switch chat.destination {
        case let .apron(serverURL, roomId):
            let focus = focus?.destination == chat.destination ? focus?.focus : nil
            ApronChatView(
                viewModel: {
                    let room = AdapterChatViewModel(
                        adapter: ApronChatAdapter(service: apronService, serverURL: serverURL, roomId: roomId, title: chat.title),
                        accountId: Account.apronId(serverURL: serverURL),
                        snapshotCache: apronService.snapshotCache,
                        draftStore: apronService.draftStore,
                    )
                    room.focusMessageId = focus?.messageId
                    return opened(room, chat: chat)
                }(),
                profileUserId: focus?.userId,
            )
        case let .spotify(chatId):
            if let makeChat = spotifyChat(chat.accountId, chatId, chat.title) {
                NetworkChatView(viewModel: opened(makeChat(), chat: chat))
            } else {
                ContentUnavailableView("Spotify Not Connected", systemImage: "music.note")
            }
        case let .instagram(threadFbid):
            if let makeChat = instagramChat(chat.accountId, threadFbid, chat.title) {
                NetworkChatView(viewModel: opened(makeChat(), chat: chat))
            } else {
                ContentUnavailableView("Instagram Not Connected", systemImage: "camera")
            }
        case let .telegram(peer):
            if let make = telegramChat(chat.accountId, peer, chat.title, chat.presence) {
                TelegramChatView(viewModel: opened(make.chat(), chat: chat), members: make.members())
            } else {
                ContentUnavailableView("Telegram Not Connected", systemImage: "paperplane")
            }
        case let .x(conversationId):
            if let makeChat = xChat(chat.accountId, conversationId, chat.title) {
                NetworkChatView(viewModel: opened(makeChat(), chat: chat))
            } else {
                ContentUnavailableView("X Chat Locked", systemImage: "lock", description: Text("Enter your X Chat PIN in this X account's settings."))
            }
        }
    }
}

/// Telegram's Archive folder: the chats the user archived there, newest first.
private struct ArchivedChatsView: View {
    @ObservedObject var viewModel: ChatListViewModel
    let destination: (ChatSummary) -> AnyView
    @State private var selection: ChatSummary?

    var body: some View {
        List(viewModel.archivedChats) { chat in
            Button {
                selection = chat
            } label: {
                ChatRow(chat: chat)
            }
            .buttonStyle(.plain)
            .listRowSeparator(chat.id == viewModel.archivedChats.first?.id ? .hidden : .automatic, edges: .top)
            .compactListRowInsets()
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.archivedChats.isEmpty {
                ContentUnavailableView("No Archived Chats", systemImage: "archivebox")
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .navigationTitle("Archived Chats")
        .navigationDestination(item: $selection) { chat in
            destination(chat)
        }
        .task(id: selection == nil) {
            guard selection == nil else { return }
            await viewModel.load()
        }
    }
}

/// The row that opens the archive: the archived chats' names, and how many have unread messages.
private struct ArchivedChatsRow: View {
    let chats: [ChatSummary]
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    private var unreadChats: Int {
        chats.count(where: { $0.unreadCount > 0 })
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.18))
                Image(systemName: "archivebox.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Archived Chats")
                    .font(.headline)
                HStack(alignment: .top) {
                    Text(chats.map { DebugRedaction.chatTitle($0, enabled: redactionEnabled) }.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if unreadChats > 0 {
                        // Gray, as in Telegram: archived chats don't call for attention.
                        Text("\(unreadChats)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.gray, in: Capsule())
                    }
                }
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A dot that is green while every connection loads and red, after the failing networks' icons, when one
/// fails; tapping it lists each connection and why any failed.
private struct ConnectionStatusButton: View {
    @ObservedObject var viewModel: ChatListViewModel
    @State private var isShowingStatus = false

    var body: some View {
        Button {
            isShowingStatus = true
        } label: {
            HStack(spacing: 4) {
                ForEach(failedNetworks, id: \.self) { network in
                    NetworkBadgeIcon(network: network)
                }
                Image(systemName: failures == 0 ? "circle.fill" : "exclamationmark.circle.fill")
                    .imageScale(failures == 0 ? .small : .medium)
                    .foregroundStyle(failures == 0 ? .green : .red)
            }
        }
        .accessibilityLabel("Connections")
        .accessibilityValue(failures == 0 ? "All connected" : "\(failures) failed")
        .popover(isPresented: $isShowingStatus) {
            ConnectionStatusList(viewModel: viewModel)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var failures: Int {
        viewModel.connections.count { $0.error != nil }
    }

    /// Each network with a failed connection, once, in list order.
    private var failedNetworks: [SocialNetwork] {
        viewModel.connections.filter { $0.error != nil }.map(\.network).reduce(into: []) { networks, network in
            if !networks.contains(network) {
                networks.append(network)
            }
        }
    }
}

private struct ConnectionStatusList: View {
    @ObservedObject var viewModel: ChatListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.connections) { connection in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: connection.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(connection.error == nil ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.label)
                        Text(connection.error ?? "Connected")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if viewModel.connections.contains(where: { $0.error != nil }) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Text("Retry")
                    }
                }
                .disabled(viewModel.isLoading)
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    private static let avatarSize: CGFloat = 48
    private static let spacing: CGFloat = 10

    /// The time today, the short weekday within the past week, then numeric day and month this year, adding
    /// the year before that, each in the user's locale order.
    static func timeLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        if days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.defaultDigits))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ChatSummaryAvatar(chat: chat, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DebugRedaction.chatTitle(chat, enabled: redactionEnabled))
                        .font(.headline)
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Muted")
                    }
                    Spacer(minLength: 8)
                    if let timestamp = chat.timestamp {
                        Text(Self.timeLabel(for: timestamp))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(chat.preview.map { DebugRedaction.chatPreview($0, chat: chat, enabled: redactionEnabled) } ?? chat.subtitle ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if chat.unreadCount > 0 {
                        Text(chat.unreadCount >= ApronNotificationSource.unreadCap ? "\(ApronNotificationSource.unreadCap)+" : "\(chat.unreadCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            // Gray for muted chats, as in Telegram.
                            .background(chat.isMuted ? Color.gray : Color.blue, in: Capsule())
                    }
                }
            }
        }
        // The separator starts at the text, after the avatar.
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.avatarSize + Self.spacing }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The chat's picture, or its initial, with the network badge in the corner.
private struct ChatSummaryAvatar: View {
    let chat: ChatSummary
    let size: CGFloat
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        Group {
            // Profile photos identify people as names do, so redaction shows the initial instead.
            if let url = chat.avatarURL, !redactionEnabled {
                CachedAsyncImage(url: url) { fallback } failure: { fallback }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            // An opaque backing, since some badges (such as Spotify's round logo) have transparent corners.
            NetworkBadgeIcon(network: chat.network, size: 16)
                .padding(1.5)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: 2, y: 2)
        }
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            Text(DebugRedaction.chatTitle(chat, enabled: redactionEnabled).first.map { String($0).uppercased() } ?? "?")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
