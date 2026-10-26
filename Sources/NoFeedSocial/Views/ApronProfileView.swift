import NoFeedSocialCore
import SwiftUI

/// One Apron user's profile: avatar, name, `@user_id` (§3.3.1 says to show it where there is room), status
/// (§4.5), roles (§3.3.4) and bio (`ext.bio`). Reads the chat's kept object, so live changes show.
struct ApronProfileView: View {
    @ObservedObject var viewModel: ApronChatViewModel
    let user: ApronUser

    var body: some View {
        let user = viewModel.currentUser(user)
        let presence = viewModel.presence(of: user)
        let isYou = viewModel.isOwnUser(user)
        List {
            Section {
                VStack(spacing: 6) {
                    ApronUserAvatar(user: user, avatarURL: viewModel.avatarURL(for: user), presence: presence, size: 96, ringColor: Color(uiColor: .systemGroupedBackground), dotScale: 1 / 5)
                        .padding(.bottom, 6)
                    HStack(spacing: 6) {
                        Text(user.displayName)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        ApronUserTags(roles: user.roles, isYou: isYou)
                    }
                    Text("@\(user.userId)")
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
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                Section("Bio") {
                    Text(Self.linkingURLs(in: bio))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bios are untrusted text, so only web links found in it become tappable, like links in messages.
    private static func linkingURLs(in text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower ..< upper].link = url
        }
        return result
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
    let user: ApronUser
    let avatarURL: URL?
    let presence: ApronPresence?
    var size: CGFloat = 36
    /// What the dot's ring blends into: the row's background by default.
    var ringColor = Color(uiColor: .secondarySystemGroupedBackground)
    /// The dot's diameter as a share of the avatar's.
    var dotScale: CGFloat = 1 / 3

    var body: some View {
        image
            .frame(width: size, height: size)
            .clipShape(Circle())
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
            Color(uiColor: ApronUserColor.color(for: user.userId))
            Text(user.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
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
