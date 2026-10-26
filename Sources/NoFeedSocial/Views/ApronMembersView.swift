import NoFeedSocialCore
import SwiftUI

/// The open room's members, from the chat's live member list (§4.2.1, §4.2.2), split into online and offline
/// when the server reports statuses (§4.5).
struct ApronMembersView: View {
    @ObservedObject var viewModel: ApronChatViewModel

    var body: some View {
        Group {
            if let members = viewModel.members {
                List {
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
                    if let total = viewModel.memberCount, total > members.count {
                        Section {} footer: {
                            Text("Showing \(members.count) of \(total) members.")
                        }
                    }
                }
            } else if viewModel.state == .connected {
                // Servers without `rooms` don't list members (§4.2.1).
                ContentUnavailableView("No Member List", systemImage: "person.2", description: Text("This server doesn't list room members."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(memberTitle)
        .navigationBarTitleDisplayMode(.inline)
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
    let user: ApronUser
    let avatarURL: URL?
    let isYou: Bool
    let presence: ApronPresence?

    var body: some View {
        HStack(spacing: 12) {
            ApronUserAvatar(user: user, avatarURL: avatarURL, presence: presence)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .lineLimit(1)
                    ApronUserTags(roles: user.roles, isYou: isYou)
                }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
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
