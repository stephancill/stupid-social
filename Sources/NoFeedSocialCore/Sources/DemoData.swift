import Foundation

#if DEBUG

    /// Generates deterministic, clearly-fake-but-realistic content so a reviewer or
    /// simulator capture can browse a populated feed and stories bar without any live
    /// network credentials. Debug-only; never compiled into the App Store build.
    public enum DemoData {
        static let viewerAccountId = "demo-viewer"

        /// Set once demo mode is active for the session; refresh services check it and keep
        /// returning preview content instead of hitting live networks. Touched only from
        /// the main actor during app startup, so an unsynchronized flag is safe.
        public nonisolated(unsafe) static var isDemoMode = false

        public static func enableDemoMode() {
            isDemoMode = true
        }

        public static func disableDemoMode() {
            isDemoMode = false
        }

        public static var shouldAutoLoad: Bool {
            CommandLine.arguments.contains("-demoData")
                || ProcessInfo.processInfo.environment["DEMO_DATA"] == "1"
        }

        // MARK: - Feed

        public static func feedItems(now: Date = Date()) -> [NotificationItem] {
            func mins(_ m: Double) -> Date {
                now.addingTimeInterval(-60 * m)
            }

            let xAlex = actor("alex_smith", "Alex Smith", .x)
            let xJules = actor("jules_dev", "Jules", .x)
            let fcNova = actor("nova.builds", "Nova", .farcaster)
            let fcRiley = actor("riley.wtf", "riley", .farcaster)
            let bsMaya = actor("maya.co", "maya", .bluesky)
            let bsKade = actor("kade.bsky.social", "Kade", .bluesky)
            let igAmy = actor("amy_stories", "Amy", .instagram)

            let xReplyTarget = NotificationTarget(
                id: "1101",
                text: "Love this — finally a feed I can open without getting lost. Shipping!",
                url: URL(string: "https://x.com/alex_smith/status/1101"),
                imageURL: placeholderImage("reply-coast"),
                author: xAlex,
                postedAt: mins(3),
            )
            let xLikeTarget = NotificationTarget(
                id: "2204",
                text: "@stephancill your microcopy about avoiding algorithmic feeds is spot on.",
                url: URL(string: "https://x.com/jules_dev/status/2204"),
                author: xJules,
                postedAt: mins(11),
                likeCount: 2,
            )
            let bsReplyTarget = NotificationTarget(
                id: "3305",
                text: "Big fan of showing notifications without the feed.",
                url: nil,
                author: bsMaya,
                postedAt: mins(14),
            )
            let igMsgTarget = NotificationTarget(
                id: "4401",
                text: "Do you have an invite code? I want in!",
                url: nil,
                imageURL: media("message-sunset"),
                author: igAmy,
                postedAt: mins(18),
            )
            let ghStarTarget = NotificationTarget(id: "5501", text: "stupid-social", url: URL(string: "https://github.com/stephancill/stupid-social")!)
            let bsLikeTarget = NotificationTarget(id: "3306", text: "You can feel the algorithms adjusting.", url: nil, imageURL: media("algorithms"), author: bsKade, postedAt: mins(26))
            let fcReplyTarget = NotificationTarget(
                id: "2206",
                text: "This is the calm feed I came here for.",
                url: nil,
                author: fcRiley,
                postedAt: mins(31),
            )

            return [
                NotificationItem(
                    id: "demo-x-reply-1",
                    network: .x,
                    accountId: viewerAccountId,
                    sourceId: "1101",
                    type: .reply,
                    timestamp: mins(3),
                    text: "@alex_smith replied to your post",
                    actors: [xAlex],
                    target: xReplyTarget,
                ),
                NotificationItem(
                    id: "demo-fc-follow-1",
                    network: .farcaster,
                    accountId: viewerAccountId,
                    sourceId: "2202",
                    type: .follow,
                    timestamp: mins(8),
                    text: "@nova.builds followed you",
                    actors: [fcNova],
                    target: nil,
                ),
                NotificationItem(
                    id: "demo-x-like-1",
                    network: .x,
                    accountId: viewerAccountId,
                    sourceId: "2204",
                    type: .mention,
                    timestamp: mins(11),
                    text: "@jules_dev mentioned you in a post",
                    actors: [xJules],
                    target: xLikeTarget,
                ),
                NotificationItem(
                    id: "demo-bs-reply-1",
                    network: .bluesky,
                    accountId: viewerAccountId,
                    sourceId: "3305",
                    type: .reply,
                    timestamp: mins(14),
                    text: "@maya.co replied to your post",
                    actors: [bsMaya],
                    target: bsReplyTarget,
                ),
                NotificationItem(
                    id: "demo-ig-message-1",
                    network: .instagram,
                    accountId: viewerAccountId,
                    sourceId: "4401",
                    type: .message,
                    timestamp: mins(18),
                    text: "@amy_stories sent you a message",
                    actors: [igAmy],
                    target: igMsgTarget,
                ),
                NotificationItem(
                    id: "demo-gh-star-1",
                    network: .github,
                    accountId: viewerAccountId,
                    sourceId: "5501",
                    type: .reaction,
                    timestamp: mins(22),
                    text: "@kade.bsky.social starred your repository",
                    actors: [bsKade],
                    target: ghStarTarget,
                ),
                NotificationItem(
                    id: "demo-bs-like-1",
                    network: .bluesky,
                    accountId: viewerAccountId,
                    sourceId: "3306",
                    type: .reaction,
                    timestamp: mins(26),
                    text: "@kade.bsky.social liked your post",
                    actors: [bsKade],
                    target: bsLikeTarget,
                ),
                NotificationItem(
                    id: "demo-fc-reply-1",
                    network: .farcaster,
                    accountId: viewerAccountId,
                    sourceId: "2206",
                    type: .reply,
                    timestamp: mins(31),
                    text: "@riley.wtf replied to your cast",
                    actors: [fcRiley],
                    target: fcReplyTarget,
                ),
                NotificationItem(
                    id: "demo-x-follow-1",
                    network: .x,
                    accountId: viewerAccountId,
                    sourceId: "3308",
                    type: .follow,
                    timestamp: mins(36),
                    text: "@jules_dev followed you",
                    actors: [xJules],
                    target: nil,
                ),
            ]
        }

        // MARK: - Stories

        public static func storyBarItems(now: Date = Date()) -> [StoryBarItem] {
            let igAlix = actor("alix.photos", "alix", .instagram)
            let igMiles = actor("miles.j", "Miles", .instagram)
            let spotifyNico = actor("nico", "Nico", .spotify)
            let ghTorres = actor("torres", "torres", .github)
            let ghPearl = actor("pearl.dev", "Pearl", .github)

            let alixReel = InstagramStoryReel(
                id: "demo-ig-alix",
                user: igAlix,
                slides: [
                    InstagramStorySlide(
                        id: "demo-ig-alix-1",
                        imageURL: placeholderImage("alix-coast"),
                        videoURL: nil,
                        isVideo: false,
                        takenAt: now.addingTimeInterval(-60 * 6).timeIntervalSince1970,
                    ),
                    InstagramStorySlide(
                        id: "demo-ig-alix-2",
                        imageURL: placeholderImage("alix-sunset"),
                        videoURL: nil,
                        isVideo: false,
                        music: InstagramStoryMusic(title: "Sunshine", artist: "Luna", artworkURL: placeholderImage("sunshine-art")),
                        takenAt: now.addingTimeInterval(-60 * 4).timeIntervalSince1970,
                    ),
                ],
            )
            let milesReel = InstagramStoryReel(
                id: "demo-ig-miles",
                user: igMiles,
                slides: [
                    InstagramStorySlide(
                        id: "demo-ig-miles-1",
                        imageURL: placeholderImage("miles-board"),
                        videoURL: nil,
                        isVideo: false,
                        takenAt: now.addingTimeInterval(-60 * 12).timeIntervalSince1970,
                    ),
                ],
            )

            let spotify = SpotifyActivityItem(
                id: "demo-sp-1",
                timestamp: now.addingTimeInterval(-60 * 2),
                userName: "Nico",
                userURI: "spotify:demo:nico",
                userAvatarURL: avatar(spotifyNico.username),
                trackName: "Midnight City",
                artistName: "Riddle",
                albumName: "Neon Drift",
                contextName: nil,
                trackURI: "spotify:track:demo1",
                trackURL: URL(string: "https://open.spotify.com/track/demo"),
                imageURL: placeholderImage("neon-drift"),
                musicAnimation: MusicAnimationMetadata(tempo: 114, tempoConfidence: 0.8, loudness: -7.2, mode: 1),
            )

            let ghStarGroup = GitHubActivityGroup(
                actor: ghTorres,
                activities: [
                    GitHubActivityItem(
                        id: "demo-gh-star-1",
                        kind: .starredRepository,
                        timestamp: now.addingTimeInterval(-60 * 5),
                        actor: ghTorres,
                        targetId: "swiftui-gallery",
                        targetName: "demo/swiftui-gallery",
                        targetURL: URL(string: "https://github.com/demo/swiftui-gallery")!,
                        targetAvatarURL: avatar(ghTorres.username),
                        summary: "starred demo/swiftui-gallery",
                        repoDescription: "A gallery of modern SwiftUI patterns.",
                        repoLanguage: "Swift",
                        repoStars: "12.4k",
                        repoLanguageColor: "#F05138",
                    ),
                ],
            )
            let ghFollowGroup = GitHubActivityGroup(
                actor: ghPearl,
                activities: [
                    GitHubActivityItem(
                        id: "demo-gh-follow-1",
                        kind: .followed,
                        timestamp: now.addingTimeInterval(-60 * 9),
                        actor: ghPearl,
                        targetId: "felix",
                        targetName: "felix",
                        targetURL: URL(string: "https://github.com/felix")!,
                        targetAvatarURL: avatar(ghPearl.username),
                        summary: "followed you",
                        followUserDisplayName: "Felix",
                        followUserBio: "Indie maker. Privacy first.",
                    ),
                ],
            )

            return [
                .instagram(alixReel),
                .instagram(milesReel),
                .spotify(spotify),
                .github(ghStarGroup),
                .github(ghFollowGroup),
            ]
        }

        // MARK: - Helpers

        private static func actor(_ username: String, _ displayName: String, _ network: SocialNetwork) -> NotificationActor {
            NotificationActor(
                id: "\(network.rawValue)-\(username)",
                network: network,
                username: username,
                displayName: displayName,
                avatarURL: avatar(username),
            )
        }

        private static func avatar(_ seed: String?) -> URL? {
            guard let seed else { return nil }
            // Female-presenting personas use randomuser.me women portraits (guaranteed female).
            if ["jules_dev", "maya.co"].contains(seed) {
                let n = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 60
                return URL(string: "https://randomuser.me/api/portraits/women/\(n).jpg")
            }
            // torres gets a distinct male portrait so it never collides with the pravatar faces.
            if seed == "torres" {
                let n = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 90
                return URL(string: "https://randomuser.me/api/portraits/men/\(n).jpg")
            }
            // pravatar's `?u=` seed is unreliable (collides); derive a stable image index from
            // the name so each persona gets a distinct face.
            let basis = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            let index = (basis % 70) + 1
            return URL(string: "https://i.pravatar.cc/120?img=\(index)")
        }

        private static func placeholderImage(_ seed: String) -> URL {
            URL(string: "https://picsum.photos/seed/\(seed)/1080/1920")!
        }

        private static func media(_ seed: String) -> URL? {
            URL(string: "https://picsum.photos/seed/\(seed)/1200/1000")
        }
    }

#endif
