import StupidSocialCore
import SwiftUI

/// A Telegram user's profile: photo, name, `@username`, last seen and bio, with a button that opens your
/// private chat with them. Laid out like Apron's profile.
struct TelegramProfileView: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @StateObject private var viewModel: TelegramProfileViewModel
    /// The chat the profile was opened from; Message isn't offered when it is already your chat with them.
    private let openChat: TelegramPeer?

    init(viewModel: @autoclosure @escaping () -> TelegramProfileViewModel, openChat: TelegramPeer? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.openChat = openChat
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

    private func content(_ profile: TelegramProfile) -> some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ChatAvatarImage(url: profile.avatarURL, title: profile.name, size: 96, colorKey: String(profile.id))
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
                    if profile.isBot {
                        Text("bot")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let status = profile.status, status != .unknown {
                        Text(status.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let peer = profile.peer, !profile.isYou, peer != openChat {
                        Button {
                            NotificationRouter.shared.pendingChat = .telegram(peer: peer)
                        } label: {
                            Image(systemName: "message.fill")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("Message")
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if let about = profile.about {
                Section("Bio") {
                    Text(AttributedString(linkingWebURLsIn: about))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
