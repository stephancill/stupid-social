import StupidSocialCore
import SwiftUI

/// The open room's details (§4.2): title, description, editable where the room offers it, then its members, from
/// the chat's live member list (§4.2.1, §4.2.2), online ones first, then by when they were last seen (§4.5).
struct ApronMembersView: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @ObservedObject var viewModel: ApronRoomViewModel
    @State private var query = ""
    @State private var isEditing = false

    var body: some View {
        Group {
            if let allMembers = viewModel.members {
                let members = ordered(filtered(allMembers))
                let total = viewModel.memberCount ?? 0
                List {
                    header
                    notificationSection
                    ServerChatsSection(label: "Show All Rooms", filter: viewModel.serverFilter)
                    MembersSection(
                        query: $query,
                        hasResults: !members.isEmpty,
                        footer: total > allMembers.count ? "Showing \(allMembers.count) of \(total) members." : nil,
                    ) {
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
                    }
                }
            } else if viewModel.isConnected {
                // Servers without `rooms` don't list members (§4.2.1).
                ContentUnavailableView("No Member List", systemImage: "person.2", description: Text("This server doesn't list room members."))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.canEdit, viewModel.isConnected {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ChatDetailsEditView(
                title: viewModel.titleIsMemberNames ? "" : viewModel.title,
                description: viewModel.roomDescription ?? "",
                requiresTitle: false,
                save: { title, description in try await viewModel.editRoom(title: title, description: description) },
            )
        }
    }

    private var title: String {
        viewModel.titleIsMemberNames ? DebugRedaction.name(viewModel.title, enabled: redactionEnabled) : viewModel.title
    }

    private var header: some View {
        ChatDetailsHeader(
            title: title,
            subtitle: viewModel.members == nil ? nil : memberTitle.lowercased(),
            description: viewModel.roomDescription,
            avatarURL: viewModel.avatarURL,
            colorKey: viewModel.avatarColorKey,
        )
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

    /// Online first, then the most recently seen; members without a time keep the list's order (you, then by name).
    private func ordered(_ members: [ApronUser]) -> [ApronUser] {
        members.enumerated().sorted { lhs, rhs in
            let lhsOnline = viewModel.presence(of: lhs.element)?.isConnected == true
            let rhsOnline = viewModel.presence(of: rhs.element)?.isConnected == true
            if lhsOnline != rhsOnline { return lhsOnline }
            let lhsSeen = lhsOnline ? nil : lhs.element.lastSeen, rhsSeen = rhsOnline ? nil : rhs.element.lastSeen
            if lhsSeen != rhsSeen { return (lhsSeen ?? .distantPast) > (rhsSeen ?? .distantPast) }
            return lhs.offset < rhs.offset
        }.map(\.element)
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
                    Text("Last seen \(ChatPresence.lastSeenTime(lastSeen))")
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
