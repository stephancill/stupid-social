import StupidSocialCore
import SwiftUI

/// A Discord chat: the shared chat, with profiles from senders' avatars and mentions; the title opens the other
/// person's profile in a DM, or a server channel's details.
struct DiscordChatView: View {
    @StateObject private var viewModel: ChatViewModel
    let profile: (_ userId: String) -> DiscordProfileViewModel
    let dmRecipient: String?
    let details: DiscordChannelDetails?
    @State private var profileUserId: String?
    @State private var showsDetails = false
    @Environment(\.serverChats) private var serverChats

    init(viewModel: @autoclosure @escaping () -> ChatViewModel, dmRecipient: String?, details: DiscordChannelDetails?, profile: @escaping (_ userId: String) -> DiscordProfileViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.dmRecipient = dmRecipient
        self.details = details
        self.profile = profile
    }

    private var onTitleTap: (() -> Void)? {
        if let dmRecipient {
            return { profileUserId = dmRecipient }
        }
        return details.map { _ in { showsDetails = true } }
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: onTitleTap,
            showProfile: { profileUserId = $0.id },
            keepsConnection: profileUserId != nil,
        )
        .navigationDestination(item: $profileUserId) { userId in
            DiscordProfileView(viewModel: profile(userId), isOpenChat: userId == dmRecipient, chat: userId == dmRecipient ? viewModel : nil)
        }
        .navigationDestination(isPresented: $showsDetails) {
            if let details {
                DiscordChannelDetailsView(details: details, chat: viewModel)
                    .environment(\.serverChats, serverChats)
            }
        }
    }
}

/// A server channel's details: its name, server and topic, and the server's other channels.
struct DiscordChannelDetailsView: View {
    let details: DiscordChannelDetails
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        List {
            ChatDetailsHeader(
                title: details.title,
                subtitle: details.serverName,
                description: details.topic,
                avatarURL: details.serverIconURL,
                colorKey: details.colorKey,
            ) {
                if chat.hasChatSettings {
                    DetailActionRow { ChatSettingsButtons(viewModel: chat) }
                }
            }
            ServerChatsSection(label: "Show All Channels", filter: details.serverFilter)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A Discord user's profile: picture, name, `@username`, pronouns and bio, with a button that opens your DM with
/// them. Laid out like Telegram's and Apron's.
struct DiscordProfileView: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @StateObject private var viewModel: DiscordProfileViewModel
    /// Message isn't offered from the DM it was opened from.
    private let isOpenChat: Bool
    /// The DM with this person when the profile opened from its title, for muting it.
    private let chat: ChatViewModel?

    init(viewModel: @autoclosure @escaping () -> DiscordProfileViewModel, isOpenChat: Bool, chat: ChatViewModel? = nil) {
        self.chat = chat
        _viewModel = StateObject(wrappedValue: viewModel())
        self.isOpenChat = isOpenChat
    }

    var body: some View {
        Group {
            if let profile = viewModel.profile {
                content(profile)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("No Profile", systemImage: "person.crop.circle.badge.questionmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private func content(_ profile: DiscordProfileViewModel.Profile) -> some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ChatAvatarImage(url: profile.avatarURL, title: profile.name, size: 96, colorKey: profile.id)
                        .opensFullScreenPhoto(profile.avatarURL, fullURL: profile.fullAvatarURL)
                        .padding(.bottom, 6)
                    Text(DebugRedaction.name(profile.name, enabled: redactionEnabled))
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if let username = profile.username {
                        Text(redactionEnabled ? "@Redacted" : "@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    if let detail = [profile.isBot ? "bot" : nil, profile.pronouns].compactMap(\.self).first {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    let canMessage = !profile.isYou && !isOpenChat
                    if canMessage || chat?.hasChatSettings == true {
                        DetailActionRow {
                            if canMessage {
                                DetailActionButton(title: "Message", systemImage: "message.fill", isWorking: viewModel.isOpeningChat) {
                                    Task {
                                        if let destination = await viewModel.openChat() {
                                            NotificationRouter.shared.pendingChat = destination
                                        }
                                    }
                                }
                            }
                            if let chat {
                                ChatSettingsButtons(viewModel: chat)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if let bio = profile.bio {
                Section("Bio") {
                    Text(AttributedString(linkingWebURLsIn: bio))
                        .textSelection(.enabled)
                }
            }
            if profile.mutualServers > 0 {
                Section {
                    LabeledContent("Mutual Servers", value: "\(profile.mutualServers)")
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
