import NoFeedSocialCore
import NoFeedSocialPush
import SwiftUI

/// A Telegram chat: the shared chat, with the member list opened from the title in groups.
struct TelegramChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var members: TelegramMembersViewModel
    @State private var showsMembers = false

    init(viewModel: @autoclosure @escaping () -> ChatViewModel, members: @autoclosure @escaping () -> TelegramMembersViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
        _members = StateObject(wrappedValue: members())
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: members.isGroup ? { showsMembers = true } : nil,
            keepsConnection: showsMembers,
        )
        .navigationDestination(isPresented: $showsMembers) {
            TelegramMembersView(viewModel: members)
        }
        .onAppear {
            NotificationRouter.shared.telegramChatDidOpen(members.peer)
        }
        .onDisappear {
            NotificationRouter.shared.telegramChatDidClose(members.peer)
        }
    }
}

/// A Telegram group's members, online ones first, as Telegram lists them.
struct TelegramMembersView: View {
    @ObservedObject var viewModel: TelegramMembersViewModel
    @State private var query = ""

    var body: some View {
        Group {
            if let list = viewModel.members {
                let members = filtered(list.members)
                let online = members.filter { $0.status == .online }
                let others = members.filter { $0.status != .online }.sorted { $0.lastSeenOrder > $1.lastSeenOrder }
                List {
                    if !online.isEmpty {
                        memberSection("Online", online)
                    }
                    if !others.isEmpty {
                        memberSection(online.isEmpty ? nil : "Offline", others)
                    }
                    if list.count > list.members.count {
                        Section {} footer: {
                            Text("Showing \(list.members.count) of \(list.count) members.")
                        }
                    }
                }
                .overlay {
                    if members.isEmpty, !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("No Member List", systemImage: "person.2", description: Text(error))
            } else {
                ProgressView()
            }
        }
        // On the screen rather than the list, so it is under the title from the start, not added once members load.
        .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(memberTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    /// Members whose name or username contains the query.
    private func filtered(_ members: [TelegramMember]) -> [TelegramMember] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return members }
        return members.filter { $0.name.localizedStandardContains(query) || ($0.username ?? "").localizedStandardContains(query) }
    }

    private func memberSection(_ title: String?, _ members: [TelegramMember]) -> some View {
        Section {
            ForEach(members) { member in
                TelegramMemberRow(member: member)
            }
        } header: {
            if let title {
                Text(title)
            }
        }
    }

    private var memberTitle: String {
        guard let count = viewModel.members?.count else { return "Members" }
        return count == 1 ? "1 Member" : "\(count) Members"
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
