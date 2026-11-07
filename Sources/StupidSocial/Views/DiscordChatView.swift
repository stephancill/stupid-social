import StupidSocialCore
import SwiftUI

/// A Discord chat: the shared chat, with profiles from senders' avatars and mentions, and in a DM the other
/// person's profile from the title.
struct DiscordChatView: View {
    @StateObject private var viewModel: ChatViewModel
    let channelId: String
    let profile: (_ userId: String) -> DiscordProfileViewModel
    let dmRecipient: String?
    @State private var profileUserId: String?

    init(viewModel: @autoclosure @escaping () -> ChatViewModel, channelId: String, dmRecipient: String?, profile: @escaping (_ userId: String) -> DiscordProfileViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.channelId = channelId
        self.dmRecipient = dmRecipient
        self.profile = profile
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: dmRecipient.map { recipient in { profileUserId = recipient } },
            showProfile: { profileUserId = $0.id },
            keepsConnection: profileUserId != nil,
        )
        .navigationDestination(item: $profileUserId) { userId in
            DiscordProfileView(viewModel: profile(userId), isOpenChat: userId == dmRecipient)
        }
    }
}

/// A Discord user's profile: picture, name, `@username`, pronouns and bio, with a button that opens your DM with
/// them. Laid out like Telegram's and Apron's.
struct DiscordProfileView: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @StateObject private var viewModel: DiscordProfileViewModel
    /// Message isn't offered from the DM it was opened from.
    private let isOpenChat: Bool

    init(viewModel: @autoclosure @escaping () -> DiscordProfileViewModel, isOpenChat: Bool) {
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
                    if !profile.isYou, !isOpenChat {
                        Button {
                            Task {
                                if let destination = await viewModel.openChat() {
                                    NotificationRouter.shared.pendingChat = destination
                                }
                            }
                        } label: {
                            if viewModel.isOpeningChat {
                                ProgressView()
                            } else {
                                Image(systemName: "message.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .disabled(viewModel.isOpeningChat)
                        .accessibilityLabel("Message")
                        .padding(.top, 10)
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
