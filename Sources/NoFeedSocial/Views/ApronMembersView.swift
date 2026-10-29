import NoFeedSocialCore
import SwiftUI

/// The open room's members, from the chat's live member list (§4.2.1, §4.2.2), split into online and offline
/// when the server reports statuses (§4.5).
struct ApronMembersView: View {
    @ObservedObject var viewModel: ApronRoomViewModel
    @State private var query = ""

    var body: some View {
        Group {
            if let allMembers = viewModel.members {
                let members = filtered(allMembers)
                List {
                    if query.isEmpty {
                        notificationSection
                    }
                    if members.contains(where: { viewModel.presence(of: $0) != nil }) {
                        let online = members.filter { viewModel.presence(of: $0)?.isConnected == true }
                        let offline = members.filter { viewModel.presence(of: $0)?.isConnected != true }
                        if !online.isEmpty {
                            memberSection("Online", online)
                        }
                        if !offline.isEmpty {
                            memberSection("Offline", offline)
                        }
                    } else {
                        memberSection(nil, members)
                    }
                    if let total = viewModel.memberCount, total > allMembers.count {
                        Section {} footer: {
                            Text("Showing \(allMembers.count) of \(total) members.")
                        }
                    }
                }
                .overlay {
                    if members.isEmpty, !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } else if viewModel.isConnected {
                // Servers without `rooms` don't list members (§4.2.1).
                ContentUnavailableView("No Member List", systemImage: "person.2", description: Text("This server doesn't list room members."))
            } else {
                ProgressView()
            }
        }
        // On the screen rather than the list, so it is under the title from the start, not added once members load.
        .searchBar(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(memberTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The room's notification level, kept by the server for all of the user's devices.
    @ViewBuilder
    private var notificationSection: some View {
        if let notifications = viewModel.notifications, notifications.options.count > 1 {
            Section {
                Picker("Notifications", selection: Binding(
                    get: { notifications.level },
                    set: { level in Task { await viewModel.setNotificationLevel(level) } },
                )) {
                    ForEach(notifications.options, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
            } footer: {
                if let error = viewModel.notificationError {
                    Text(error)
                }
            }
        }
    }

    /// Members whose name or `@user_id` contains the query.
    private func filtered(_ members: [ApronUser]) -> [ApronUser] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return members }
        return members.filter { $0.displayName.localizedStandardContains(query) || $0.userId.localizedStandardContains(query) }
    }

    private func memberSection(_ title: String?, _ members: [ApronUser]) -> some View {
        Section {
            ForEach(members, id: \.userId) { member in
                NavigationLink {
                    ApronProfileView(viewModel: viewModel, user: member)
                } label: {
                    ApronMemberRow(
                        user: member,
                        avatarURL: viewModel.avatarURL(for: member),
                        isYou: viewModel.isOwnUser(member),
                        presence: viewModel.presence(of: member),
                    )
                }
            }
        } header: {
            if let title {
                Text(title)
            }
        }
    }

    private var memberTitle: String {
        guard let members = viewModel.members else { return "Members" }
        let count = max(viewModel.memberCount ?? 0, members.count)
        return count == 1 ? "1 Member" : "\(count) Members"
    }
}

private struct ApronMemberRow: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    let user: ApronUser
    let avatarURL: URL?
    let isYou: Bool
    let presence: ApronPresence?

    var body: some View {
        HStack(spacing: 12) {
            ApronUserAvatar(user: user, avatarURL: avatarURL, presence: presence)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(DebugRedaction.name(user.displayName, enabled: redactionEnabled))
                        .lineLimit(1)
                    ApronUserTags(roles: user.roles, isYou: isYou)
                }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if presence == .offline, !isYou, let lastSeen = user.lastSeen {
                    Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The statuses a dot alone doesn't explain.
    private var details: [String] {
        switch presence {
        case .idle, .doNotDisturb, .other: presence.map { [$0.label] } ?? []
        default: []
        }
    }
}
