import NoFeedSocialCore
import SwiftUI

/// Every chat across networks, newest first; the page to the left of the feed.
struct ChatsView: View {
    @ObservedObject var viewModel: ChatListViewModel
    let apronService: ApronService
    /// The chat for a Spotify chat id and title; `nil` when Spotify isn't connected.
    let spotifyChat: (_ chatId: String, _ title: String) -> (() -> ChatViewModel)?
    /// The chat for an Instagram thread and title; `nil` when Instagram isn't connected.
    let instagramChat: (_ threadFbid: String, _ title: String) -> (() -> ChatViewModel)?
    let telegramChat: (_ peer: TelegramPeer, _ title: String) -> () -> ChatViewModel
    /// Whether a chat is pushed, so the home pager can stop paging.
    @Binding var isShowingChat: Bool
    /// A chat to open, such as from a tapped notification; cleared once opened.
    @Binding var openRequest: ChatSummary.Destination?
    @State private var selection: ChatSummary?
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
                    ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right", description: Text(viewModel.errorMessage ?? "Chats from Apron servers, Spotify, Instagram and Telegram appear here."))
                } else {
                    ProgressView()
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = viewModel.errorMessage, !viewModel.chats.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
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
        .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: selection == nil && !isShowingArchive) { _, isOnList in
            isShowingChat = !isOnList
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
            guard selection?.destination != request else { return }
            let chat = chat(for: request)
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
        // Reloads on returning from a chat too, so unread counts and latest messages stay current.
        .task(id: selection == nil) {
            guard selection == nil else { return }
            await viewModel.load()
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
        )
    }

    @ViewBuilder
    private func destination(for chat: ChatSummary) -> some View {
        switch chat.destination {
        case let .apron(serverURL, roomId):
            ApronChatView(viewModel: viewModel.follow(
                ApronChatViewModel(service: apronService, serverURL: serverURL, roomId: roomId, title: chat.title, expectsUnread: chat.unreadCount > 0),
                chatId: chat.id,
            ))
        case let .spotify(chatId):
            if let makeChat = spotifyChat(chatId, chat.title) {
                NetworkChatView(viewModel: viewModel.follow(makeChat(), chatId: chat.id))
            } else {
                ContentUnavailableView("Spotify Not Connected", systemImage: "music.note")
            }
        case let .instagram(threadFbid):
            if let makeChat = instagramChat(threadFbid, chat.title) {
                NetworkChatView(viewModel: viewModel.follow(makeChat(), chatId: chat.id))
            } else {
                ContentUnavailableView("Instagram Not Connected", systemImage: "camera")
            }
        case let .telegram(peer):
            NetworkChatView(viewModel: viewModel.follow(telegramChat(peer, chat.title)(), chatId: chat.id))
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
                            .background(.blue, in: Capsule())
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
            if let url = chat.avatarURL {
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
