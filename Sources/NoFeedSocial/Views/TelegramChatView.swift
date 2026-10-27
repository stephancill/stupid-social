import NoFeedSocialCore
import SwiftUI

/// A Telegram chat: the shared chat, with the member list opened from the title in groups.
struct TelegramChatView: View {
    @StateObject private var viewModel: TelegramChatViewModel
    @State private var showsMembers = false

    init(viewModel: @autoclosure @escaping () -> TelegramChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: viewModel.isGroup ? { showsMembers = true } : nil,
            keepsConnection: showsMembers,
        )
        .navigationDestination(isPresented: $showsMembers) {
            TelegramMembersView(viewModel: viewModel)
        }
    }
}

/// A Telegram group's members, online ones first, as Telegram lists them.
struct TelegramMembersView: View {
    @ObservedObject var viewModel: TelegramChatViewModel

    var body: some View {
        Group {
            if let list = viewModel.members {
                let online = list.members.filter { $0.status == .online }
                let others = list.members.filter { $0.status != .online }.sorted { $0.lastSeenOrder > $1.lastSeenOrder }
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
            } else if let error = viewModel.membersError {
                ContentUnavailableView("No Member List", systemImage: "person.2", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(memberTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadMembers() }
        .refreshable { await viewModel.loadMembers() }
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
    /// Like Telegram: "online", "last seen 5 minutes ago", or roughly when the exact time is private.
    var statusText: String? {
        if isBot { return "bot" }
        switch status {
        case .online: return "online"
        case let .lastSeen(date): return "last seen \(date.formatted(.relative(presentation: .named)))"
        case .recently: return "last seen recently"
        case .lastWeek: return "last seen within a week"
        case .lastMonth: return "last seen within a month"
        case .unknown: return "last seen a long time ago"
        }
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
