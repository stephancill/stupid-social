import NoFeedSocialCore
import NoFeedSocialPush
import SwiftUI

/// One Apron user's profile: avatar, name, `@user_id` (§3.3.1 says to show it where there is room), status
/// (§4.5), roles (§3.3.4) and bio (`ext.bio`). Reads the chat's kept object, so live changes show.
struct ApronProfileView: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @ObservedObject var viewModel: ApronRoomViewModel
    let user: ApronUser
    @State private var isOpeningMessage = false
    @State private var messageError: String?

    var body: some View {
        let user = viewModel.currentUser(user)
        let presence = viewModel.presence(of: user)
        let isYou = viewModel.isOwnUser(user)
        List {
            Section {
                VStack(spacing: 6) {
                    ApronUserAvatar(user: user, avatarURL: viewModel.avatarURL(for: user), presence: presence, size: 96, ringColor: Color(uiColor: .systemGroupedBackground), dotScale: 1 / 5, hasBorder: true)
                        .padding(.bottom, 6)
                    HStack(spacing: 6) {
                        Text(DebugRedaction.name(user.displayName, enabled: redactionEnabled))
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        ApronUserTags(roles: user.roles, isYou: isYou)
                    }
                    Text(redactionEnabled ? "@Redacted" : "@\(user.userId)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    // The dot already says online or offline; only the other statuses need words.
                    if let presence, presence != .online, presence != .offline {
                        Text(presence.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if presence == .offline, !isYou, let lastSeen = user.lastSeen {
                        Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.canMessage(user) {
                        messageButton(for: user)
                            .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                Section("Bio") {
                    Text(AttributedString(linkingWebURLsIn: bio))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(DebugRedaction.name(user.displayName, enabled: redactionEnabled))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func messageButton(for user: ApronUser) -> some View {
        Button {
            Task { await openMessage(with: user) }
        } label: {
            // The icon keeps sizing the button while hidden, so the spinner doesn't enlarge it.
            Image(systemName: "message.fill")
                .opacity(isOpeningMessage ? 0 : 1)
                .overlay {
                    if isOpeningMessage {
                        ProgressView()
                    }
                }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Message")
        .disabled(isOpeningMessage)
        if let messageError {
            Text(messageError)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Opens your private room with the user on the Chats side like a tapped notification, or a new chat with
    /// them whose first message starts the room.
    private func openMessage(with user: ApronUser) async {
        isOpeningMessage = true
        messageError = nil
        defer { isOpeningMessage = false }
        do {
            if let roomId = try await viewModel.existingDirectRoom(with: user) {
                NotificationRouter.shared.pendingChat = .apron(serverURL: viewModel.serverURL, roomId: roomId)
            } else {
                NotificationRouter.shared.pendingChat = .apronDirect(serverURL: viewModel.serverURL, user: user)
            }
        } catch {
            messageError = error.localizedDescription
        }
    }
}

/// Tags beside a name: "you" on your own, then server roles (§3.3.4). Styled like the "You follow each other"
/// tag on profiles.
struct ApronUserTags: View {
    let roles: [String]?
    let isYou: Bool

    var body: some View {
        ForEach((isYou ? ["you"] : []) + (roles ?? []), id: \.self) { tag in
            Text(tag)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.1), in: Capsule())
                .fixedSize()
        }
    }
}

/// A user's avatar, or initials on their chat color, with a dot for a known status.
struct ApronUserAvatar: View {
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    let user: ApronUser
    let avatarURL: URL?
    let presence: ApronPresence?
    var size: CGFloat = 36
    /// What the dot's ring blends into: the row's background by default.
    var ringColor = Color(uiColor: .secondarySystemGroupedBackground)
    /// The dot's diameter as a share of the avatar's.
    var dotScale: CGFloat = 1 / 3
    /// A thin muted ring around the avatar, under the dot.
    var hasBorder = false

    var body: some View {
        image
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if hasBorder {
                    Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let color = presence?.dotColor {
                    let dot = size * dotScale
                    // Centers the dot on the avatar's edge at 45°, where the circle is at 0.854 of the frame.
                    let offset = dot / 2 - size * (1 - 0.854)
                    Circle()
                        .fill(color)
                        .frame(width: dot, height: dot)
                        .overlay { Circle().stroke(ringColor, lineWidth: max(2, size / 24)) }
                        .offset(x: offset, y: offset)
                }
            }
    }

    @ViewBuilder
    private var image: some View {
        if let avatarURL {
            CachedAsyncImage(url: avatarURL) { initials } failure: { initials }
        } else {
            initials
        }
    }

    private var initials: some View {
        ZStack {
            Color(uiColor: ChatUserColor.color(for: user.userId))
            Text(DebugRedaction.name(user.displayName, enabled: redactionEnabled).split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

extension ApronPresence {
    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .offline: "Offline"
        case let .other(value): value
        }
    }

    var dotColor: Color? {
        switch self {
        case .online: .green
        case .idle: .yellow
        case .doNotDisturb: .red
        case .offline: .gray
        case .other: nil
        }
    }
}

extension AttributedString {
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bios are untrusted text, so only web links found in it become tappable, like links in messages.
    init(linkingWebURLsIn text: String) {
        self.init(text)
        for match in Self.linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: self),
                  let upper = AttributedString.Index(range.upperBound, within: self)
            else { continue }
            self[lower ..< upper].link = url
        }
    }
}
