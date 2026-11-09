import SwiftUI

/// A chat's picture, or in its place the initials of its (already redacted) title on the chat color of
/// `colorKey` (as on Apron profiles), else its initial on gray. The Chats row and the chat's title show the same one.
public struct ChatAvatarImage: View {
    let url: URL?
    let title: String
    let size: CGFloat
    var colorKey: String?
    @AppStorage(ChatRedaction.defaultsKey) private var redactionEnabled = false

    public init(url: URL?, title: String, size: CGFloat, colorKey: String? = nil) {
        self.url = url
        self.title = title
        self.size = size
        self.colorKey = colorKey
    }

    public var body: some View {
        Group {
            // Profile photos identify people as names do, so redaction shows the initial instead.
            if let url, !redactionEnabled {
                CachedAsyncImage(url: url) { fallback } failure: { fallback }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Group {
            if let colorKey {
                ZStack {
                    Color(uiColor: ChatUserColor.color(for: colorKey))
                    Text(InitialsAvatar.initials(of: title))
                        .font(.system(size: size * 0.39, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.18))
                    Text(title.first.map { String($0).uppercased() } ?? "?")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
