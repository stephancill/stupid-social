import StupidSocialCore
import StupidSocialPush
import SwiftUI

/// A Telegram chat: the shared chat, with the group's details and members, or the other person's profile in a
/// private chat, opened from the title, and profiles from mentions and senders' avatars.
struct TelegramChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var members: TelegramMembersViewModel
    @State private var showsMembers = false
    /// The user id, or `@username`, whose profile is open.
    @State private var profileTarget: String?

    init(viewModel: @autoclosure @escaping () -> ChatViewModel, members: @autoclosure @escaping () -> TelegramMembersViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
        _members = StateObject(wrappedValue: members())
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: members.isGroup ? { showsMembers = true } : { profileTarget = String(members.peer.id) },
            showProfile: { profileTarget = $0.id },
            keepsConnection: showsMembers || profileTarget != nil,
        )
        .navigationDestination(isPresented: $showsMembers) {
            TelegramMembersView(viewModel: members)
        }
        .navigationDestination(item: $profileTarget) { target in
            TelegramProfileView(viewModel: members.profile(for: target), openChat: members.peer)
        }
        .onAppear {
            NotificationRouter.shared.telegramChatDidOpen(members.peer)
        }
        .onDisappear {
            NotificationRouter.shared.telegramChatDidClose(members.peer)
        }
    }
}

/// A Telegram group's details (photo, title, description), editable with the right to change them, then its
/// members, online ones first, then by when they were last seen.
struct TelegramMembersView: View {
    @ObservedObject var viewModel: TelegramMembersViewModel
    @State private var query = ""
    @State private var isEditing = false

    var body: some View {
        Group {
            if let list = viewModel.members {
                // Telegram's order breaks ties: the sort keeps it, since members are enumerated first.
                let members = filtered(list.members).enumerated()
                    .sorted { $0.element.lastSeenOrder != $1.element.lastSeenOrder ? $0.element.lastSeenOrder > $1.element.lastSeenOrder : $0.offset < $1.offset }
                    .map(\.element)
                List {
                    header
                    MembersSection(
                        query: $query,
                        hasResults: !members.isEmpty,
                        footer: list.count > list.members.count ? "Showing \(list.members.count) of \(list.count) members." : nil,
                    ) {
                        ForEach(members) { member in
                            NavigationLink {
                                TelegramProfileView(viewModel: viewModel.profile(for: String(member.id)))
                            } label: {
                                TelegramMemberRow(member: member)
                            }
                        }
                    }
                }
            } else if let error = viewModel.errorMessage {
                List {
                    header
                    Section {
                        ContentUnavailableView("No Member List", systemImage: "person.2", description: Text(error))
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.info?.canEdit == true {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let info = viewModel.info {
                ChatDetailsEditView(
                    title: info.title,
                    description: info.about ?? "",
                    save: { title, about in try await viewModel.edit(title: title, about: about) },
                )
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private var header: some View {
        if let info = viewModel.info {
            ChatDetailsHeader(
                title: info.title,
                subtitle: info.memberCount.map { $0 == 1 ? "1 member" : "\($0) members" },
                description: info.about,
                avatarURL: info.avatarURL,
                fullAvatarURL: info.fullAvatarURL,
                colorKey: String(viewModel.peer.id),
            )
        }
    }

    /// Members whose name or username contains the query.
    private func filtered(_ members: [TelegramMember]) -> [TelegramMember] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return members }
        return members.filter { $0.name.localizedStandardContains(query) || ($0.username ?? "").localizedStandardContains(query) }
    }
}

private struct TelegramMemberRow: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    let member: TelegramMember

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(DebugRedaction.name(member.name, enabled: redactionEnabled))
                        .lineLimit(1)
                    ApronUserTags(roles: tags, isYou: member.isYou)
                }
                if let status = member.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(member.status == .online ? Color.accentColor : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tags: [String] {
        switch member.role {
        case .owner: ["owner"]
        case .admin: ["admin"]
        case .member: member.isBot ? ["bot"] : []
        }
    }

    private var avatar: some View {
        Group {
            if let url = member.avatarURL {
                CachedAsyncImage(url: url) { initials } failure: { initials }
            } else {
                initials
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            Color(uiColor: ChatUserColor.color(for: String(member.id)))
            Text(DebugRedaction.name(member.name, enabled: redactionEnabled).split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

private extension TelegramMember {
    var statusText: String? {
        isBot ? "bot" : status.text
    }

    /// Most recently seen first; rough statuses sort after exact times within their range.
    var lastSeenOrder: TimeInterval {
        let now = Date().timeIntervalSince1970
        switch status {
        case .online: return .infinity
        case let .lastSeen(date): return date.timeIntervalSince1970
        case .recently: return now - 3 * 86400
        case .lastWeek: return now - 7 * 86400
        case .lastMonth: return now - 30 * 86400
        case .unknown: return 0
        }
    }
}
