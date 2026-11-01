import Foundation

/// Generates deterministic, clearly-fake-but-realistic content so a reviewer or
/// simulator capture can browse a populated feed and stories bar without any live
/// network credentials. Available through the hidden developer settings.
public enum DemoData {
    public static let viewerAccountId = "demo-viewer"

    public static var isDemoMode: Bool {
        UserDefaults.standard.bool(forKey: "demoModeEnabled")
    }

    public static func enableDemoMode() {
        UserDefaults.standard.set(true, forKey: "demoModeEnabled")
    }

    public static func disableDemoMode() {
        UserDefaults.standard.set(false, forKey: "demoModeEnabled")
    }

    public static var shouldAutoLoad: Bool {
        isDemoMode || CommandLine.arguments.contains("-demoData")
            || ProcessInfo.processInfo.environment["DEMO_DATA"] == "1"
    }

    // MARK: - Feed

    public static func feedItems(now: Date = Date()) -> [NotificationItem] {
        func mins(_ m: Double) -> Date {
            now.addingTimeInterval(-60 * m)
        }

        // The same people as the demo chats, with their faces, on each network's kind of handle.
        let samAvatar = URL(string: "https://randomuser.me/api/portraits/men/22.jpg")
        let you = NotificationActor(id: "x-sam", network: .x, username: "sam", displayName: "Sam", avatarURL: samAvatar)
        let xMaya = person("maya_chen", "Maya Chen", .x, DemoChats.maya)
        let xTheo = person("theo_builds", "Theo", .x, DemoChats.theo)
        let xJules = person("julesmakes", "Jules", .x, DemoChats.jules)
        let xRiley = person("rileyw", "Riley", .x, DemoChats.riley)
        let bsJules = person("jules.bsky.social", "Jules", .bluesky, DemoChats.jules)
        let bsMaya = person("maya.bsky.social", "Maya Chen", .bluesky, DemoChats.maya)
        let fcNova = person("nova", "Nova", .farcaster, DemoChats.nova)
        let fcRiley = person("riley", "Riley", .farcaster, DemoChats.riley)
        let igAmy = person("amy.k", "Amy", .instagram, DemoChats.amy)
        let ghKade = person("kade-codes", "Kade", .github, DemoChats.kade)

        let farmPost = NotificationTarget(
            id: "1101",
            text: "Last light on the farm tonight 🌾",
            url: URL(string: "https://x.com/sam/status/1101"),
            imageURL: media("golden-hour"),
            author: you,
            postedAt: mins(40),
            likeCount: 24,
        )
        let julesReply = NotificationTarget(
            id: "3305",
            text: "Okay this settles it, we're doing the coast road in May 🚗",
            url: nil,
            author: bsJules,
            postedAt: mins(5),
        )
        let theoMention = NotificationTarget(
            id: "2204",
            text: "Huge thanks to @sam for the trip planning template, saved us hours",
            url: URL(string: "https://x.com/theo_builds/status/2204"),
            author: xTheo,
            postedAt: mins(14),
            likeCount: 8,
        )
        let trailPhoto = NotificationTarget(
            id: "4401",
            text: "Sunday trail 🥾",
            url: nil,
            imageURL: media("cabin-view"),
            author: NotificationActor(id: "instagram-sam", network: .instagram, username: "sam", displayName: "Sam", avatarURL: samAvatar),
            postedAt: mins(90),
        )
        let repo = NotificationTarget(id: "5501", text: "sam/trailmap", url: URL(string: "https://github.com/sam/trailmap")!)
        let rileyReply = NotificationTarget(
            id: "2206",
            text: "Those colours 🔥 what were you shooting on?",
            url: nil,
            author: fcRiley,
            postedAt: mins(33),
        )

        return [
            NotificationItem(
                id: "demo-x-like-1",
                network: .x,
                accountId: viewerAccountId,
                sourceId: "1101",
                type: .reaction,
                timestamp: mins(2),
                text: "maya_chen and 3 others liked your post",
                actors: [xMaya, xTheo, xJules, xRiley],
                target: farmPost,
            ),
            NotificationItem(
                id: "demo-bs-reply-1",
                network: .bluesky,
                accountId: viewerAccountId,
                sourceId: "3305",
                type: .reply,
                timestamp: mins(5),
                text: "@jules.bsky.social replied to your post",
                actors: [bsJules],
                target: julesReply,
            ),
            NotificationItem(
                id: "demo-fc-follow-1",
                network: .farcaster,
                accountId: viewerAccountId,
                sourceId: "2202",
                type: .follow,
                timestamp: mins(9),
                text: "@nova followed you",
                actors: [fcNova],
                target: nil,
            ),
            NotificationItem(
                id: "demo-x-mention-1",
                network: .x,
                accountId: viewerAccountId,
                sourceId: "2204",
                type: .mention,
                timestamp: mins(14),
                text: "@theo_builds mentioned you in a post",
                actors: [xTheo],
                target: theoMention,
            ),
            NotificationItem(
                id: "demo-ig-like-1",
                network: .instagram,
                accountId: viewerAccountId,
                sourceId: "4401",
                type: .reaction,
                timestamp: mins(19),
                text: "amy.k liked your photo",
                actors: [igAmy],
                target: trailPhoto,
            ),
            NotificationItem(
                id: "demo-gh-star-1",
                network: .github,
                accountId: viewerAccountId,
                sourceId: "5501",
                type: .reaction,
                timestamp: mins(24),
                text: "kade-codes starred your repository",
                actors: [ghKade],
                target: repo,
            ),
            NotificationItem(
                id: "demo-fc-reply-1",
                network: .farcaster,
                accountId: viewerAccountId,
                sourceId: "2206",
                type: .reply,
                timestamp: mins(33),
                text: "@riley replied to your cast",
                actors: [fcRiley],
                target: rileyReply,
            ),
            NotificationItem(
                id: "demo-bs-follow-1",
                network: .bluesky,
                accountId: viewerAccountId,
                sourceId: "3308",
                type: .follow,
                timestamp: mins(41),
                text: "@maya.bsky.social followed you",
                actors: [bsMaya],
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

    private static func person(_ username: String, _ displayName: String, _ network: SocialNetwork, _ user: ChatUser) -> NotificationActor {
        NotificationActor(
            id: "\(network.rawValue)-\(username)",
            network: network,
            username: username,
            displayName: displayName,
            avatarURL: user.avatarURL,
        )
    }

    private static func avatar(_ seed: String?) -> URL? {
        guard let seed else { return nil }
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
