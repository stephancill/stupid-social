import Foundation

/// Moves the one account per network from before multi-account support into the `AccountStore`, once per
/// device. Each becomes an account whose id is the network's name ("x", "instagram"…), which is the Keychain
/// item its credentials are already in, so nothing about the credentials moves (except X Chat keys, which
/// gain the account's id). Every device migrates to the same ids and order, so their entries merge.
enum AccountMigration {
    private static let doneKey = "accounts.migratedLegacy"

    static func migrateIfNeeded(store: AccountStore, defaults: UserDefaults, keychain: KeychainCredentialStore) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let legacy = LegacyAccountMetadata(defaults: defaults)
        var migrated: [(Account, AccountStatusSnapshot?)] = []

        func add(_ network: SocialNetwork, _ status: AccountStatusSnapshot?, _ build: (inout Account) -> Void) {
            // Fixed dates keep the migrated accounts in this order, identically on every device.
            var account = Account(id: network.rawValue, network: network, addedAt: Date(timeIntervalSince1970: TimeInterval(migrated.count)))
            build(&account)
            migrated.append((account, status))
        }

        let xMetadata = legacy.load(XAccountMetadata.self, key: LegacyAccountMetadata.Key.xAccount)
        if xMetadata != nil || (try? keychain.loadXCredentials()) != nil {
            add(.x, xMetadata?.status) { account in
                account.handle = xMetadata?.handle
                var categories = xMetadata?.enabledCategories ?? Set(XNotificationCategory.allCases)
                // Accounts from before the "follows" category get it enabled once.
                if !defaults.bool(forKey: LegacyAccountMetadata.Key.xFollowsMigrated) {
                    categories.insert(.follows)
                }
                account.preferences.xCategories = categories
            }
            keychain.scoped(to: SocialNetwork.x.rawValue).adoptLegacyXChatKeys()
        }

        if let farcaster = legacy.load(FarcasterAccountMetadata.self, key: LegacyAccountMetadata.Key.farcasterAccount) {
            add(.farcaster, farcaster.status) { account in
                account.remoteId = String(farcaster.fid)
                account.handle = farcaster.username
                account.preferences.farcasterCategories = farcaster.enabledCategories
            }
        }

        let instagram = legacy.load(InstagramAccountMetadata.self, key: LegacyAccountMetadata.Key.instagramAccount)
        let instagramCredentials = try? keychain.loadInstagramCredentials()
        if instagram != nil || instagramCredentials != nil {
            add(.instagram, instagram?.status) { account in
                let metadataId = instagram?.accountId == "instagram" ? nil : instagram?.accountId
                account.remoteId = metadataId ?? instagramCredentials?.dsUserId
                account.handle = instagram?.username
                account.avatarURL = instagram?.avatarURL
                account.preferences.instagramCategories = instagram?.enabledCategories
                account.preferences.instagramStoriesEnabled = instagram?.storiesEnabled
                account.preferences.instagramDirectMediaSharesEnabled = instagram?.directMediaSharesEnabled
            }
        }

        let bluesky = legacy.load(BlueskyAccountMetadata.self, key: LegacyAccountMetadata.Key.blueskyAccount)
        let blueskyCredentials = try? keychain.loadBlueskyCredentials()
        if bluesky != nil || blueskyCredentials != nil {
            add(.bluesky, bluesky?.status) { account in
                account.remoteId = bluesky?.did ?? blueskyCredentials?.did
                account.handle = bluesky?.handle ?? blueskyCredentials?.handle
            }
        }

        let spotify = legacy.load(SpotifyAccountMetadata.self, key: LegacyAccountMetadata.Key.spotifyAccount)
        let spotifyCredentials = try? keychain.loadSpotifyCredentials()
        if spotify != nil || spotifyCredentials != nil {
            add(.spotify, spotify?.status) { account in
                let username = spotify?.username ?? spotifyCredentials?.username
                account.remoteId = username
                account.handle = username
            }
        }

        let github = legacy.load(GitHubAccountMetadata.self, key: LegacyAccountMetadata.Key.githubAccount)
        let githubCredentials = try? keychain.loadGitHubCredentials()
        if github != nil || githubCredentials != nil {
            add(.github, github?.status) { account in
                let username = github?.username ?? githubCredentials?.username
                account.remoteId = username
                account.handle = username
            }
        }

        if let telegram = keychain.loadTelegramSession().flatMap(TelegramClient.signedInAccount(sessionData:)) {
            add(.telegram, .valid) { account in
                account.remoteId = String(telegram.userId)
                account.handle = telegram.username
                account.displayName = telegram.name
            }
        }

        for server in legacy.load([ApronServerMetadata].self, key: LegacyAccountMetadata.Key.apronServers) ?? [] {
            var account = Account(
                id: Account.apronId(serverURL: server.serverURL),
                network: .apron,
                remoteId: server.user?.userId,
                displayName: server.user?.name,
                serverURL: server.serverURL,
                addedAt: Date(timeIntervalSince1970: TimeInterval(migrated.count)),
            )
            account.preferences.apronRequestedName = server.requestedName
            migrated.append((account, server.status))
            store.setApronInfo(ApronSignInInfo(user: server.user, agent: server.agent, welcome: server.welcome), id: account.id)
        }

        for (account, status) in migrated {
            store.save(account, at: account.addedAt)
            if let status {
                store.setStatus(status, id: account.id)
            }
        }
        legacy.removeAll()
        defaults.set(true, forKey: doneKey)
    }
}
