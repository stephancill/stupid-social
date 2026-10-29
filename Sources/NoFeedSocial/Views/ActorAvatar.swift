import NoFeedSocialCore
import SwiftUI

/// A notification actor's round picture, or their initial while it loads or when there is none.
struct ActorAvatar: View {
    let actor: NotificationActor
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarURL = actor.avatarURL {
                CachedAsyncImage(url: avatarURL) {
                    ActorAvatarFallback(actor: actor)
                } failure: {
                    ActorAvatarFallback(actor: actor)
                }
            } else {
                ActorAvatarFallback(actor: actor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct ActorAvatarFallback: View {
    let actor: NotificationActor
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))

            Text(initial)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = DebugRedaction.actorName(actor, enabled: redactionEnabled)
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
