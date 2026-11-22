import StupidSocialCore
import SwiftUI

/// A chat on a network without a details screen of its own: the shared chat, whose title opens the other person's
/// profile in a one-to-one chat on a network with profiles (`ChatProfileLinking`), else `ChatInfoView`.
struct InfoChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @Environment(\.feedService) private var feedService
    @State private var showsInfo = false
    @State private var profileActor: NotificationActor?

    init(viewModel: @autoclosure @escaping () -> ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ChatView(viewModel: viewModel, onTitleTap: openDetails)
            .navigationDestination(isPresented: $showsInfo) {
                ChatInfoView(viewModel: viewModel)
            }
            .navigationDestination(item: $profileActor) { actor in
                if let feedService {
                    ProfileDetailView(actor: actor, feedService: feedService, accountId: (viewModel as? any ChatProfileProviding)?.accountId, chat: viewModel)
                }
            }
    }

    private func openDetails() {
        if feedService != nil, let actor = (viewModel as? any ChatProfileProviding)?.profileActor {
            profileActor = actor
        } else {
            showsInfo = true
        }
    }
}

/// A chat whose adapter can name the other person, for opening their profile from the chat's title.
@MainActor
protocol ChatProfileProviding {
    var accountId: String { get }
    var profileActor: NotificationActor? { get }
}

extension AdapterChatViewModel: ChatProfileProviding {
    var profileActor: NotificationActor? {
        (adapter as? any ChatProfileLinking)?.profileActor
    }
}

extension EnvironmentValues {
    /// Profiles and posts, for chats that open someone's profile.
    @Entry var feedService: FeedService?
}

/// A chat's details: its picture, title and subtitle, with Mute and Archive buttons where its network has them,
/// then a group's description and members where its adapter lists them (`ChatMembersListing`).
struct ChatInfoView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @State private var details: (description: String?, members: [ChatMemberSummary])?
    @State private var query = ""

    var body: some View {
        List {
            ChatDetailsHeader(
                title: viewModel.titleNamesPeople ? DebugRedaction.name(viewModel.title, enabled: redactionEnabled) : viewModel.title,
                subtitle: details.map { "\($0.members.count) members" } ?? (viewModel.subtitle.isEmpty ? nil : viewModel.subtitle),
                description: details?.description,
                avatarURL: viewModel.titleAvatar?.url,
                colorKey: viewModel.titleAvatar?.colorKey ?? viewModel.title,
            ) {
                if viewModel.hasChatSettings {
                    DetailActionRow { ChatSettingsButtons(viewModel: viewModel) }
                }
            }
            if let members = details?.members, !members.isEmpty {
                let filtered = query.isEmpty ? members : members.filter { $0.name.localizedStandardContains(query) }
                MembersSection(query: $query, hasResults: !filtered.isEmpty) {
                    ForEach(filtered) { member in
                        ChatMemberRow(member: member)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            details = await (viewModel as? any ChatMembersListingProviding)?.groupDetails()
        }
    }
}

/// A chat view model whose adapter lists a group's members.
@MainActor
protocol ChatMembersListingProviding {
    func groupDetails() async -> (description: String?, members: [ChatMemberSummary])?
}

extension AdapterChatViewModel: ChatMembersListingProviding {
    func groupDetails() async -> (description: String?, members: [ChatMemberSummary])? {
        await (adapter as? any ChatMembersListing)?.groupDetails()
    }
}

private struct ChatMemberRow: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    let member: ChatMemberSummary

    var body: some View {
        HStack(spacing: 12) {
            avatar
            HStack(spacing: 6) {
                Text(DebugRedaction.name(member.name, enabled: redactionEnabled))
                    .lineLimit(1)
                ApronUserTags(roles: member.tags, isYou: member.isYou)
            }
        }
        .accessibilityElement(children: .combine)
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
            Color(uiColor: ChatUserColor.color(for: member.id))
            Text(DebugRedaction.name(member.name, enabled: redactionEnabled).split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// A round button with its name below, in the row of actions under a profile or chat header (Message, Mute,
/// Archive). While it works, a small spinner takes the icon's place inside the icon's frame, so the button keeps
/// its size.
struct DetailActionButton: View {
    let title: String
    let systemImage: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                // A fixed frame keeps every button in the row the same size, whatever the symbol's shape.
                ZStack {
                    Image(systemName: systemImage)
                        .opacity(isWorking ? 0 : 1)
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(title)
            Text(title)
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .disabled(isWorking)
    }
}

/// The row of `DetailActionButton`s under a profile or chat header.
struct DetailActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: DetailActionRow.spacing) {
            content()
        }
        .padding(.top, 10)
    }

    static var spacing: CGFloat {
        24
    }
}

extension ChatViewModel {
    /// Whether the chat's details offer Mute or Archive: its network can change them and its Chats row says which
    /// they are.
    var hasChatSettings: Bool {
        (canMute && isMuted != nil) || (canArchive && isArchived != nil)
    }
}

/// Mute and Archive buttons for a chat's details, each shown only where the chat's network can change it. Goes in
/// a `DetailActionRow`, after any other buttons. A tap shows its result at once; a failed change goes back and says
/// why.
struct ChatSettingsButtons: View {
    @ObservedObject var viewModel: ChatViewModel
    /// The value each change in flight shows until the network confirms it.
    @State private var pendingMuted: Bool?
    @State private var pendingArchived: Bool?
    @State private var errorMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: DetailActionRow<EmptyView>.spacing) {
            if viewModel.canMute, let isMuted = pendingMuted ?? viewModel.isMuted {
                DetailActionButton(title: isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "bell.slash.fill" : "bell.fill") {
                    guard pendingMuted == nil else { return }
                    pendingMuted = !isMuted
                    save { try await viewModel.setMuted(!isMuted) } report: {
                        AppMetrics.chatMuteChanged(network: viewModel.network, muted: !isMuted, error: $0)
                    } done: { pendingMuted = nil }
                }
            }
            if viewModel.canArchive, let isArchived = pendingArchived ?? viewModel.isArchived {
                DetailActionButton(title: isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill") {
                    guard pendingArchived == nil else { return }
                    pendingArchived = !isArchived
                    save { try await viewModel.setArchived(!isArchived) } report: {
                        AppMetrics.chatArchiveChanged(network: viewModel.network, archived: !isArchived, error: $0)
                    } done: { pendingArchived = nil }
                }
            }
        }
        .alert("Couldn’t Change Chat", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {} message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(_ change: @escaping () async throws -> Void, report: @escaping ((any Error)?) -> Void, done: @escaping () -> Void) {
        errorMessage = nil
        Task {
            do {
                try await change()
                report(nil)
            } catch {
                report(error)
                errorMessage = error.localizedDescription
            }
            done()
        }
    }
}
