import Foundation
import Security

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var xCookieHeader = ""
    @Published public var farcasterUsername = ""
    @Published public var instagramCookieHeader = ""
    @Published public var spotifyBearerToken = ""
    @Published public var spotifyClientToken = ""
    @Published public var spotifySpDC = ""
    @Published public var debugServerURL = ""
    @Published public var blueskyLoginHint = ""
    @Published public var githubCookieHeader = ""
    @Published public private(set) var xStatus: AccountStatus = .notConfigured
    @Published public var xEnabledCategories: Set<XNotificationCategory> = []
    @Published public private(set) var farcasterStatus: AccountStatus = .notConfigured
    @Published public var farcasterEnabledCategories: Set<FarcasterNotificationCategory> = []
    @Published public private(set) var instagramStatus: AccountStatus = .notConfigured
    @Published public var instagramEnabledCategories: Set<InstagramNotificationCategory> = []
    @Published public var instagramStoriesEnabled = true
    @Published public var instagramDirectMediaSharesEnabled = true
    @Published public private(set) var spotifyStatus: AccountStatus = .notConfigured
    @Published public private(set) var blueskyStatus: AccountStatus = .notConfigured
    @Published public private(set) var githubStatus: AccountStatus = .notConfigured
    @Published public private(set) var debugStatus: AccountStatus = .notConfigured
    @Published public private(set) var xCredentialStorage: CredentialSaveResult?
    @Published public private(set) var instagramCredentialStorage: CredentialSaveResult?
    @Published public private(set) var spotifyCredentialStorage: CredentialSaveResult?
    @Published public private(set) var blueskyCredentialStorage: CredentialSaveResult?
    @Published public private(set) var githubCredentialStorage: CredentialSaveResult?
    @Published public var message: String?

    private let keychainStore: KeychainCredentialStore
    private let metadataStore: AccountMetadataStore
    private let farcasterClient: FarcasterClient
    private let cacheStore: NotificationCacheStore

    public init(
        keychainStore: KeychainCredentialStore,
        metadataStore: AccountMetadataStore,
        farcasterClient: FarcasterClient,
        cacheStore: NotificationCacheStore,
    ) {
        self.keychainStore = keychainStore
        self.metadataStore = metadataStore
        self.farcasterClient = farcasterClient
        self.cacheStore = cacheStore
        loadStatuses()
    }

    public var xHandle: String? {
        metadataStore.xAccount?.handle
    }

    public var farcasterHandle: String? {
        metadataStore.farcasterAccount?.username
    }

    public var xConnectionLabel: String {
        if let handle = xHandle {
            return "@\(handle)"
        }
        return xStatus.label
    }

    public var farcasterConnectionLabel: String {
        if let username = farcasterHandle {
            return "@\(username)"
        }
        return farcasterStatus.label
    }

    public var instagramHandle: String? {
        metadataStore.instagramAccount?.username
    }

    public var instagramConnectionLabel: String {
        if instagramStatus == .invalidCredentials {
            return instagramStatus.label
        }
        if let username = instagramHandle {
            return "@\(username)"
        }
        return instagramStatus.label
    }

    public func existingInstagramCredentials() -> InstagramCredentials? {
        try? keychainStore.loadInstagramCredentials()
    }

    public var debugConnectionLabel: String {
        metadataStore.debugAccount?.serverURL.absoluteString ?? debugStatus.label
    }

    public var spotifyHandle: String? {
        metadataStore.spotifyAccount?.username
    }

    public var spotifyConnectionLabel: String {
        if let username = spotifyHandle {
            return "@\(username)"
        }
        return spotifyStatus.label
    }

    public var blueskyHandle: String? {
        metadataStore.blueskyAccount?.handle
    }

    public var blueskyConnectionLabel: String {
        if let handle = blueskyHandle {
            return "@\(handle)"
        }
        return blueskyStatus.label
    }

    public var githubHandle: String? {
        metadataStore.githubAccount?.username
    }

    public var githubConnectionLabel: String {
        if githubStatus == .invalidCredentials { return githubStatus.label }
        if let githubHandle { return "@\(githubHandle)" }
        return githubStatus.label
    }

    public var hasInvalidCredentials: Bool {
        xStatus == .invalidCredentials
            || instagramStatus == .invalidCredentials
            || spotifyStatus == .invalidCredentials
            || blueskyStatus == .invalidCredentials
            || githubStatus == .invalidCredentials
    }

    public var hasLocalOnlyCredentials: Bool {
        xCredentialStorage == .localOnly
            || instagramCredentialStorage == .localOnly
            || spotifyCredentialStorage == .localOnly
            || blueskyCredentialStorage == .localOnly
            || githubCredentialStorage == .localOnly
    }

    public func beginBlueskyOAuth() async throws -> BlueskyOAuthSession {
        let hint = blueskyLoginHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await BlueskyClient(credentialStore: keychainStore).startOAuth(loginHint: hint.isEmpty ? nil : hint)
    }

    public func finishBlueskyOAuth(callbackURL: URL, session: BlueskyOAuthSession) async {
        do {
            let credentials = try await BlueskyClient(credentialStore: keychainStore).finishOAuth(callbackURL: callbackURL, session: session)
            metadataStore.blueskyAccount = BlueskyAccountMetadata(did: credentials.did, handle: credentials.handle, status: .valid)
            refreshCredentialStorageStatuses()
            blueskyStatus = .valid
            blueskyLoginHint = ""
            message = "Bluesky account connected."
        } catch {
            blueskyStatus = .serviceError("OAuth failed")
            message = "Bluesky login failed: \(error.localizedDescription)"
        }
    }

    public func saveXCookies(_ credentials: XCredentials) async {
        do {
            xCredentialStorage = try keychainStore.saveXCredentials(credentials)
            xStatus = .valid
            message = "X credentials saved."
        } catch {
            xStatus = .serviceError("Could not save credentials")
            message = "Could not save X credentials."
            return
        }

        do {
            let user = try await XClient(credentialStore: keychainStore).verifiedUser()
            let categories = metadataStore.xAccount?.enabledCategories ?? Set(XNotificationCategory.allCases)
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: user.screenName, status: .valid, enabledCategories: categories)
            xEnabledCategories = categories
            xStatus = .valid
            message = "X credentials saved."
        } catch {
            let categories = metadataStore.xAccount?.enabledCategories ?? Set(XNotificationCategory.allCases)
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .valid, enabledCategories: categories)
            xEnabledCategories = categories
            message = "X credentials saved, but could not resolve username."
        }
    }

    public func saveGitHubCookies(_ credentials: GitHubCredentials) async {
        do {
            githubCredentialStorage = try keychainStore.saveGitHubCredentials(credentials)
            let result = try await GitHubClient().forYouFeed(credentials: credentials)
            guard case let .feed(response) = result else { throw SourceError.invalidResponse }
            _ = try GitHubActivityParser.parse(response.html)
            let accountId = credentials.username ?? "github"
            metadataStore.githubAccount = GitHubAccountMetadata(accountId: accountId, username: credentials.username, status: .valid)
            githubStatus = .valid
            message = "GitHub account connected."
        } catch SourceError.notConfigured {
            try? keychainStore.deleteGitHubCredentials()
            githubCredentialStorage = nil
            githubStatus = .invalidCredentials
            message = "GitHub login expired. Log in again."
        } catch {
            try? keychainStore.deleteGitHubCredentials()
            githubCredentialStorage = nil
            githubStatus = .serviceError("Validation failed")
            message = "Could not connect GitHub: \(error.localizedDescription)"
        }
    }

    public func saveGitHubCookieHeader() async {
        guard let credentials = CookieHeaderParser.extractGitHubCredentials(from: githubCookieHeader) else {
            githubStatus = .invalidCredentials
            message = "GitHub cookie header must include user_session and __Host-user_session_same_site."
            return
        }
        githubCookieHeader = ""
        await saveGitHubCookies(credentials)
    }

    public func saveXCookieHeader() async {
        guard let credentials = CookieHeaderParser.extractXCredentials(from: xCookieHeader) else {
            xStatus = .invalidCredentials
            message = "X cookie header must include auth_token and ct0."
            return
        }

        do {
            xCredentialStorage = try keychainStore.saveXCredentials(credentials)
            xCookieHeader = ""
            xStatus = .valid
            message = "X credentials saved."
        } catch {
            xStatus = .serviceError("Could not save credentials")
            message = "Could not save X credentials."
            return
        }

        do {
            let user = try await XClient(credentialStore: keychainStore).verifiedUser()
            let categories = metadataStore.xAccount?.enabledCategories ?? Set(XNotificationCategory.allCases)
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: user.screenName, status: .valid, enabledCategories: categories)
            xEnabledCategories = categories
            xStatus = .valid
            message = "X credentials saved."
        } catch {
            let categories = metadataStore.xAccount?.enabledCategories ?? Set(XNotificationCategory.allCases)
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .valid, enabledCategories: categories)
            xEnabledCategories = categories
            message = "X credentials saved, but could not resolve username."
        }
    }

    public func saveFarcasterUsername() async {
        let username = farcasterUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            farcasterStatus = .notConfigured
            message = "Enter a Farcaster username."
            return
        }

        do {
            let user = try await farcasterClient.user(byUsername: username)
            metadataStore.farcasterAccount = FarcasterAccountMetadata(
                username: user.username ?? username,
                fid: user.fid,
                status: .valid,
                enabledCategories: Set(FarcasterNotificationCategory.allCases),
            )
            farcasterEnabledCategories = Set(FarcasterNotificationCategory.allCases)
            farcasterStatus = .valid
            message = "Farcaster account saved."
        } catch {
            farcasterStatus = .serviceError("Could not resolve username")
            message = "Could not resolve Farcaster username."
        }
    }

    public func saveInstagramCookies(_ credentials: InstagramCredentials) async {
        do {
            instagramCredentialStorage = try keychainStore.saveInstagramCredentials(credentials)
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch {
            instagramStatus = .serviceError("Could not save credentials")
            message = "Could not save Instagram credentials."
            return
        }

        do {
            let user = try await InstagramClient(credentialStore: keychainStore).currentUserProfile()
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = instagramMetadata(from: user, categories: categories)
            instagramEnabledCategories = categories
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch SourceError.notConfigured {
            deleteInstagramCredentialsForFailedReconnect()
            message = "Instagram login expired. Log in again to reconnect."
        } catch {
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: "instagram",
                username: nil,
                status: .valid,
                enabledCategories: categories,
            )
            instagramEnabledCategories = categories
            message = "Instagram credentials saved, but could not resolve username."
        }
    }

    public func saveInstagramCookieHeader() async {
        guard let credentials = CookieHeaderParser.extractInstagramCredentials(from: instagramCookieHeader) else {
            instagramStatus = .invalidCredentials
            message = "Instagram cookie header must include sessionid, csrftoken, and ds_user_id."
            return
        }

        do {
            instagramCredentialStorage = try keychainStore.saveInstagramCredentials(credentials)
            instagramCookieHeader = ""
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch {
            instagramStatus = .serviceError("Could not save credentials")
            message = "Could not save Instagram credentials."
            return
        }

        do {
            let user = try await InstagramClient(credentialStore: keychainStore).currentUserProfile()
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = instagramMetadata(from: user, categories: categories)
            instagramEnabledCategories = categories
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch SourceError.notConfigured {
            deleteInstagramCredentialsForFailedReconnect()
            message = "Instagram login expired. Log in again to reconnect."
        } catch {
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: "instagram",
                username: nil,
                status: .valid,
                enabledCategories: categories,
            )
            instagramEnabledCategories = categories
            message = "Instagram credentials saved, but could not resolve username."
        }
    }

    public func saveDebugServerURL() {
        let value = debugServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "http" || url.scheme == "https" else {
            debugStatus = .serviceError("Invalid URL")
            message = "Enter an http or https debug server URL."
            return
        }

        metadataStore.debugAccount = DebugAccountMetadata(serverURL: url, status: .valid)
        debugStatus = .valid
        message = "Debug notifications server saved."
    }

    public func disconnectX() {
        try? keychainStore.deleteXCredentials()
        xCredentialStorage = nil
        metadataStore.xAccount = nil
        xEnabledCategories = []
        try? cacheStore.deleteNetwork(.x)
        xStatus = .notConfigured
        message = "X account disconnected."
    }

    public func toggleXCategory(_ category: XNotificationCategory, enabled: Bool) {
        if enabled {
            xEnabledCategories.insert(category)
        } else {
            xEnabledCategories.remove(category)
        }
        var account = metadataStore.xAccount
        account?.enabledCategories = xEnabledCategories
        if let account {
            metadataStore.xAccount = account
        }
    }

    public func disconnectFarcaster() {
        metadataStore.farcasterAccount = nil
        farcasterEnabledCategories = []
        try? cacheStore.deleteNetwork(.farcaster)
        farcasterStatus = .notConfigured
        message = "Farcaster account disconnected."
    }

    public func toggleFarcasterCategory(_ category: FarcasterNotificationCategory, enabled: Bool) {
        if enabled {
            farcasterEnabledCategories.insert(category)
        } else {
            farcasterEnabledCategories.remove(category)
        }
        var account = metadataStore.farcasterAccount
        account?.enabledCategories = farcasterEnabledCategories
        if let account {
            metadataStore.farcasterAccount = account
        }
    }

    public func disconnectInstagram() {
        try? keychainStore.deleteInstagramCredentials()
        instagramCredentialStorage = nil
        metadataStore.instagramAccount = nil
        instagramEnabledCategories = []
        instagramStoriesEnabled = true
        instagramDirectMediaSharesEnabled = true
        try? cacheStore.deleteNetwork(.instagram)
        instagramStatus = .notConfigured
        message = "Instagram account disconnected."
    }

    public func toggleInstagramCategory(_ category: InstagramNotificationCategory, enabled: Bool) {
        if enabled {
            instagramEnabledCategories.insert(category)
        } else {
            instagramEnabledCategories.remove(category)
        }
        var account = metadataStore.instagramAccount
        account?.enabledCategories = instagramEnabledCategories
        if let account {
            metadataStore.instagramAccount = account
        }
    }

    public func toggleInstagramStories(enabled: Bool) {
        instagramStoriesEnabled = enabled
        var account = metadataStore.instagramAccount
        account?.storiesEnabled = enabled
        if let account {
            metadataStore.instagramAccount = account
        }
    }

    public func toggleInstagramDirectMediaShares(enabled: Bool) {
        instagramDirectMediaSharesEnabled = enabled
        var account = metadataStore.instagramAccount
        account?.directMediaSharesEnabled = enabled
        if let account {
            metadataStore.instagramAccount = account
        }
    }

    public func saveSpotifyCredentials(_ credentials: SpotifyCredentials) async {
        do {
            spotifyCredentialStorage = try keychainStore.saveSpotifyCredentials(credentials)
        } catch {
            spotifyStatus = .serviceError("Could not save credentials")
            message = "Could not save Spotify credentials."
            return
        }

        do {
            let username = try await SpotifyClient(credentialStore: keychainStore).validateAccount()
            metadataStore.spotifyAccount = SpotifyAccountMetadata(
                accountId: "spotify",
                username: username,
                status: .valid,
            )
            spotifyStatus = .valid
            message = "Spotify credentials saved."
        } catch {
            try? keychainStore.deleteSpotifyCredentials()
            metadataStore.spotifyAccount = nil
            spotifyStatus = .serviceError("Could not resolve username")
            message = "Spotify login failed: could not resolve username. Please try logging in again."
            return
        }

        await fetchInitToken(credentials)
    }

    private func fetchInitToken(_ creds: SpotifyCredentials) async {
        guard !creds.spDC.isEmpty else { return }
        do {
            var request = URLRequest(url: URL(string: "https://open.spotify.com/api/server-time")!)
            request.setValue("application/json", forHTTPHeaderField: "accept")
            let (serverData, _) = try await URLSession.shared.data(for: request)
            let serverTime = try JSONDecoder().decode(SpotifyServerTimeResponse.self, from: serverData).serverTime

            let token = SpotifyWebPlayerToken.current(date: Date(timeIntervalSince1970: serverTime))
            var components = URLComponents(string: "https://open.spotify.com/api/token")!
            components.queryItems = [
                URLQueryItem(name: "reason", value: "init"),
                URLQueryItem(name: "productType", value: "web-player"),
                URLQueryItem(name: "totp", value: token),
                URLQueryItem(name: "totpServer", value: token),
                URLQueryItem(name: "totpVer", value: SpotifyWebPlayerToken.version),
            ]

            var tokenRequest = URLRequest(url: components.url!)
            tokenRequest.setValue("application/json", forHTTPHeaderField: "accept")
            tokenRequest.setValue(spotifyCookieHeader(for: creds), forHTTPHeaderField: "cookie")

            let (data, _) = try await URLSession.shared.data(for: tokenRequest)
            let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

            let existing = try keychainStore.loadSpotifyCredentials() ?? creds
            let enriched = SpotifyCredentials(
                bearerToken: existing.bearerToken,
                clientToken: existing.clientToken,
                spDC: existing.spDC,
                spT: existing.spT,
                spKey: existing.spKey,
                accessTokenExpiresAt: existing.accessTokenExpiresAt,
                initialBearerToken: decoded.accessToken,
                initialBearerTokenExpiresAt: decoded.accessTokenExpirationTimestampMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                username: existing.username,
            )
            spotifyCredentialStorage = try keychainStore.saveSpotifyCredentials(enriched)
        } catch {
            // init token is best-effort; transport token already saved and validated
        }
    }

    private func spotifyCookieHeader(for creds: SpotifyCredentials) -> String {
        var values = ["sp_dc=\(creds.spDC)"]
        if let spT = creds.spT, !spT.isEmpty {
            values.append("sp_t=\(spT)")
        }
        if let spKey = creds.spKey, !spKey.isEmpty {
            values.append("sp_key=\(spKey)")
        }
        return values.joined(separator: "; ")
    }

    public func saveSpotifyManualCredentials() async {
        let bearer = spotifyBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = spotifyClientToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let spDC = spotifySpDC.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bearer.isEmpty, !client.isEmpty else {
            spotifyStatus = .invalidCredentials
            message = "Bearer token and client token are required."
            return
        }

        let credentials = SpotifyCredentials(
            bearerToken: bearer,
            clientToken: client,
            spDC: spDC,
            username: nil,
        )

        do {
            spotifyCredentialStorage = try keychainStore.saveSpotifyCredentials(credentials)
            spotifyBearerToken = ""
            spotifyClientToken = ""
            spotifySpDC = ""
        } catch {
            spotifyStatus = .serviceError("Could not save credentials")
            message = "Could not save Spotify credentials."
            return
        }

        do {
            let username = try await SpotifyClient(credentialStore: keychainStore).validateAccount()
            metadataStore.spotifyAccount = SpotifyAccountMetadata(
                accountId: "spotify",
                username: username,
                status: .valid,
            )
            spotifyStatus = .valid
            message = "Spotify credentials saved."
        } catch {
            try? keychainStore.deleteSpotifyCredentials()
            metadataStore.spotifyAccount = nil
            spotifyStatus = .serviceError("Could not resolve username")
            message = "Spotify login failed: could not resolve username. Please try logging in again."
        }
    }

    public func disconnectSpotify() {
        try? keychainStore.deleteSpotifyCredentials()
        spotifyCredentialStorage = nil
        metadataStore.spotifyAccount = nil
        try? cacheStore.deleteNetwork(.spotify)
        spotifyStatus = .notConfigured
        message = "Spotify account disconnected."
    }

    public func disconnectBluesky() {
        try? keychainStore.deleteBlueskyCredentials()
        blueskyCredentialStorage = nil
        metadataStore.blueskyAccount = nil
        try? cacheStore.deleteNetwork(.bluesky)
        blueskyStatus = .notConfigured
        message = "Bluesky account disconnected."
    }

    public func disconnectGitHub() {
        try? keychainStore.deleteGitHubCredentials()
        githubCredentialStorage = nil
        metadataStore.githubAccount = nil
        githubStatus = .notConfigured
        message = "GitHub account disconnected."
    }

    public func disconnectDebug() {
        metadataStore.debugAccount = nil
        try? cacheStore.deleteNetwork(.debug)
        debugStatus = .notConfigured
        message = "Debug server disconnected."
    }

    public func loadStatuses() {
        refreshCredentialStorageStatuses()
        if let x = metadataStore.xAccount {
            xEnabledCategories = x.enabledCategories
            xStatus = accountStatus(from: x.status)
        } else {
            xEnabledCategories = []
            xStatus = .notConfigured
        }
        if let farcaster = metadataStore.farcasterAccount {
            farcasterUsername = farcaster.username
            farcasterEnabledCategories = farcaster.enabledCategories
            farcasterStatus = accountStatus(from: farcaster.status)
        } else {
            farcasterEnabledCategories = []
            farcasterStatus = .notConfigured
        }

        if let instagram = metadataStore.instagramAccount {
            instagramEnabledCategories = instagram.enabledCategories
            instagramStoriesEnabled = instagram.storiesEnabled
            instagramDirectMediaSharesEnabled = instagram.directMediaSharesEnabled
            instagramStatus = accountStatus(from: instagram.status)
        } else {
            instagramEnabledCategories = []
            instagramStoriesEnabled = true
            instagramDirectMediaSharesEnabled = true
            instagramStatus = .notConfigured
        }

        if let spotify = metadataStore.spotifyAccount {
            spotifyStatus = accountStatus(from: spotify.status)
        } else {
            spotifyStatus = .notConfigured
        }

        if let bluesky = metadataStore.blueskyAccount {
            blueskyLoginHint = bluesky.handle ?? ""
            blueskyStatus = accountStatus(from: bluesky.status)
        } else {
            blueskyStatus = .notConfigured
        }

        if let github = metadataStore.githubAccount {
            githubStatus = accountStatus(from: github.status)
        } else {
            githubStatus = .notConfigured
        }

        if let debug = metadataStore.debugAccount {
            debugServerURL = debug.serverURL.absoluteString
            debugStatus = accountStatus(from: debug.status)
        } else {
            debugStatus = .notConfigured
        }
    }

    private func accountStatus(from snapshot: AccountStatusSnapshot) -> AccountStatus {
        switch snapshot {
        case .valid: .valid
        case .invalidCredentials: .invalidCredentials
        case .iCloudUnavailable: .iCloudUnavailable
        case .notConfigured: .notConfigured
        case .networkUnavailable: .networkUnavailable
        case .serviceError: .serviceError("Validation failed")
        }
    }

    public func refreshSyncedConnections() async {
        let discoveredX = metadataStore.xAccount == nil && (try? keychainStore.loadXCredentials()) != nil
        let discoveredInstagram = metadataStore.instagramAccount == nil && (try? keychainStore.loadInstagramCredentials()) != nil
        let discoveredSpotify = metadataStore.spotifyAccount == nil && (try? keychainStore.loadSpotifyCredentials()) != nil
        let discoveredBluesky = metadataStore.blueskyAccount == nil && (try? keychainStore.loadBlueskyCredentials()) != nil
        let discoveredGitHub = metadataStore.githubAccount == nil && (try? keychainStore.loadGitHubCredentials()) != nil

        if discoveredX {
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .valid)
        }
        if discoveredInstagram, let credentials = try? keychainStore.loadInstagramCredentials() {
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: credentials.dsUserId,
                username: nil,
                status: .valid,
            )
        }
        if discoveredSpotify, let credentials = try? keychainStore.loadSpotifyCredentials() {
            metadataStore.spotifyAccount = SpotifyAccountMetadata(
                accountId: "spotify",
                username: credentials.username,
                status: .valid,
            )
        }
        if discoveredBluesky, let credentials = try? keychainStore.loadBlueskyCredentials() {
            metadataStore.blueskyAccount = BlueskyAccountMetadata(
                did: credentials.did,
                handle: credentials.handle,
                status: .valid,
            )
        }
        if discoveredGitHub, let credentials = try? keychainStore.loadGitHubCredentials() {
            metadataStore.githubAccount = GitHubAccountMetadata(
                accountId: credentials.username ?? "github",
                username: credentials.username,
                status: .valid,
            )
        }

        loadStatuses()

        if discoveredX {
            await validateDiscoveredXCredentials()
        }
        if discoveredInstagram {
            await validateDiscoveredInstagramCredentials()
        }
        if discoveredSpotify {
            await validateDiscoveredSpotifyCredentials()
        }
        if discoveredBluesky {
            await validateDiscoveredBlueskyCredentials()
        }
        if discoveredGitHub {
            await validateDiscoveredGitHubCredentials()
        }
    }

    private func refreshCredentialStorageStatuses() {
        xCredentialStorage = try? keychainStore.xCredentialStorage()
        instagramCredentialStorage = try? keychainStore.instagramCredentialStorage()
        spotifyCredentialStorage = try? keychainStore.spotifyCredentialStorage()
        blueskyCredentialStorage = try? keychainStore.blueskyCredentialStorage()
        githubCredentialStorage = try? keychainStore.githubCredentialStorage()
    }

    private func validateDiscoveredXCredentials() async {
        do {
            let user = try await XClient(credentialStore: keychainStore).verifiedUser()
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: user.screenName, status: .valid)
            xStatus = .valid
        } catch {
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .serviceError)
            xStatus = .serviceError("Validation failed")
        }
    }

    private func validateDiscoveredInstagramCredentials() async {
        do {
            let profile = try await InstagramClient(credentialStore: keychainStore).currentUserProfile()
            metadataStore.instagramAccount = instagramMetadata(from: profile, categories: Set(InstagramNotificationCategory.allCases))
            instagramStatus = .valid
        } catch SourceError.notConfigured {
            markInstagramCredentialsInvalid()
        } catch {
            if var account = metadataStore.instagramAccount {
                account.status = .serviceError
                metadataStore.instagramAccount = account
            }
            instagramStatus = .serviceError("Validation failed")
        }
    }

    private func validateDiscoveredSpotifyCredentials() async {
        do {
            let username = try await SpotifyClient(credentialStore: keychainStore).validateAccount()
            metadataStore.spotifyAccount = SpotifyAccountMetadata(accountId: "spotify", username: username, status: .valid)
            spotifyStatus = .valid
        } catch SourceError.notConfigured {
            metadataStore.spotifyAccount = SpotifyAccountMetadata(accountId: "spotify", username: nil, status: .invalidCredentials)
            spotifyStatus = .invalidCredentials
        } catch {
            metadataStore.spotifyAccount = SpotifyAccountMetadata(accountId: "spotify", username: nil, status: .serviceError)
            spotifyStatus = .serviceError("Validation failed")
        }
    }

    private func validateDiscoveredBlueskyCredentials() async {
        do {
            let profile = try await BlueskyClient(credentialStore: keychainStore).validateAccount()
            guard let credentials = try? keychainStore.loadBlueskyCredentials() else { return }
            metadataStore.blueskyAccount = BlueskyAccountMetadata(did: credentials.did, handle: profile.handle, status: .valid)
            blueskyStatus = .valid
        } catch SourceError.notConfigured {
            if var account = metadataStore.blueskyAccount {
                account.status = .invalidCredentials
                metadataStore.blueskyAccount = account
            }
            blueskyStatus = .invalidCredentials
        } catch {
            if var account = metadataStore.blueskyAccount {
                account.status = .serviceError
                metadataStore.blueskyAccount = account
            }
            blueskyStatus = .serviceError("Validation failed")
        }
    }

    private func validateDiscoveredGitHubCredentials() async {
        guard let credentials = try? keychainStore.loadGitHubCredentials() else { return }
        do {
            let result = try await GitHubClient().forYouFeed(credentials: credentials)
            guard case let .feed(response) = result else { return }
            _ = try GitHubActivityParser.parse(response.html)
            metadataStore.githubAccount = GitHubAccountMetadata(accountId: credentials.username ?? "github", username: credentials.username, status: .valid)
            githubStatus = .valid
        } catch SourceError.notConfigured {
            if var account = metadataStore.githubAccount {
                account.status = .invalidCredentials
                metadataStore.githubAccount = account
            }
            githubStatus = .invalidCredentials
        } catch {
            if var account = metadataStore.githubAccount {
                account.status = .serviceError
                metadataStore.githubAccount = account
            }
            githubStatus = .serviceError("Validation failed")
        }
    }

    private func instagramMetadata(from profile: InstagramCurrentUserProfile, categories: Set<InstagramNotificationCategory>) -> InstagramAccountMetadata {
        let existing = metadataStore.instagramAccount
        return InstagramAccountMetadata(
            accountId: String(profile.pk),
            username: profile.username,
            avatarURL: profile.profilePicURL,
            status: .valid,
            enabledCategories: categories,
            storiesEnabled: existing?.storiesEnabled ?? true,
            directMediaSharesEnabled: existing?.directMediaSharesEnabled ?? true,
        )
    }

    public func revalidateInstagram() async {
        guard metadataStore.instagramAccount != nil else { return }
        do {
            let client = InstagramClient(credentialStore: keychainStore)
            let profile = try await client.currentUserProfile()
            instagramStatus = .valid
            if var account = metadataStore.instagramAccount {
                account.accountId = String(profile.pk)
                account.username = profile.username
                account.avatarURL = profile.profilePicURL
                account.status = .valid
                metadataStore.instagramAccount = account
            }
        } catch SourceError.notConfigured {
            markInstagramCredentialsInvalid()
        } catch {
            instagramStatus = .invalidCredentials
            if var account = metadataStore.instagramAccount {
                account.status = .invalidCredentials
                metadataStore.instagramAccount = account
            }
        }
    }

    private func markInstagramCredentialsInvalid() {
        instagramStatus = .invalidCredentials
        if var account = metadataStore.instagramAccount {
            account.status = .invalidCredentials
            metadataStore.instagramAccount = account
        } else {
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: "instagram",
                username: nil,
                status: .invalidCredentials,
                enabledCategories: Set(InstagramNotificationCategory.allCases),
            )
        }
    }

    private func deleteInstagramCredentialsForFailedReconnect() {
        try? keychainStore.deleteInstagramCredentials()
        markInstagramCredentialsInvalid()
    }
}
