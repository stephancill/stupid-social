import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct ProfileDetailView: View {
    let actor: NotificationActor
    let feedService: FeedService
    @Environment(\.openURL) private var openURL

    @State private var profile: NetworkProfile?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
            } else if let profile {
                profileContent(profile)
            }
        }
        .task { await loadProfile() }
        .navigationTitle("Profile")
    }

    @ViewBuilder
    private func profileContent(_ profile: NetworkProfile) -> some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    avatarView(url: profile.avatarURL)
                        .frame(width: 80, height: 80)

                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            if let displayName = profile.displayName, !displayName.isEmpty {
                                Text(displayName)
                                    .font(.title2.weight(.bold))
                            }
                            if profile.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                            }
                        }
                        if let username = profile.username {
                            Text("@\(username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if profile.isMutualFollow == true {
                            Text("You follow each other")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if let bio = profile.bio, !bio.isEmpty {
                Section("Bio") {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }

            Section {
                LabeledContent("Followers", value: profile.followerCount.map { formatCount($0) } ?? "—")
                LabeledContent("Following", value: profile.followingCount.map { formatCount($0) } ?? "—")
                if let posts = profile.postsCount {
                    LabeledContent("Posts", value: formatCount(posts))
                }
            }

            if let joined = profile.joinedAt {
                Section {
                    LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if let website = profile.websiteURL {
                Section {
                    Button {
                        openURL(website)
                    } label: {
                        HStack {
                            Text(website.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if let url = profileURL(for: profile) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 4) {
                            Text("View on \(profile.network.displayName)")
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    @ViewBuilder
    private func avatarView(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    avatarFallback
                @unknown default:
                    avatarFallback
                }
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
            Text(initial)
                .font(.title.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = actor.username ?? actor.displayName ?? actor.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }

    private func loadProfile() async {
        isLoading = true
        errorMessage = nil
        do {
            profile = try await feedService.fetchProfile(
                for: actor.id,
                network: actor.network,
                username: actor.username
            )
        } catch {
            errorMessage = "Could not load profile."
        }
        isLoading = false
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM", millions)
        }
        if count >= 1000 {
            let thousands = Double(count) / 1000.0
            return String(format: "%.1fK", thousands)
        }
        return "\(count)"
    }

    private func profileURL(for profile: NetworkProfile) -> URL? {
        guard let username = profile.username else { return nil }
        switch profile.network {
        case .farcaster:
            return URL(string: "https://farcaster.xyz/\(username)")
        case .x:
            return URL(string: "https://x.com/\(username)")
        case .instagram:
            return URL(string: "https://www.instagram.com/\(username)/")
        case .spotify:
            return URL(string: "https://open.spotify.com/user/\(username)")
        case .debug:
            return nil
        }
    }
}
