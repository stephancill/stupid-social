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
    @Published public private(set) var xStatus: AccountStatus = .notConfigured
    @Published public var xEnabledCategories: Set<XNotificationCategory> = []
    @Published public private(set) var farcasterStatus: AccountStatus = .notConfigured
    @Published public var farcasterEnabledCategories: Set<FarcasterNotificationCategory> = []
    @Published public private(set) var instagramStatus: AccountStatus = .notConfigured
    @Published public var instagramEnabledCategories: Set<InstagramNotificationCategory> = []
    @Published public var instagramStoriesEnabled = true
    @Published public private(set) var spotifyStatus: AccountStatus = .notConfigured
    @Published public private(set) var debugStatus: AccountStatus = .notConfigured
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
        if let username = instagramHandle {
            return "@\(username)"
        }
        return instagramStatus.label
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

    public func saveXCookies(_ credentials: XCredentials) async {
        do {
            _ = try keychainStore.saveXCredentials(credentials)
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

    public func saveXCookieHeader() async {
        guard let credentials = CookieHeaderParser.extractXCredentials(from: xCookieHeader) else {
            xStatus = .invalidCredentials
            message = "X cookie header must include auth_token and ct0."
            return
        }

        do {
            _ = try keychainStore.saveXCredentials(credentials)
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
            _ = try keychainStore.saveInstagramCredentials(credentials)
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch {
            instagramStatus = .serviceError("Could not save credentials")
            message = "Could not save Instagram credentials."
            return
        }

        do {
            let user = try await InstagramClient(credentialStore: keychainStore).verifiedUser()
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: String(user.pk),
                username: user.username,
                avatarURL: user.profilePicURL,
                status: .valid,
                enabledCategories: categories,
            )
            instagramEnabledCategories = categories
            instagramStatus = .valid
            message = "Instagram credentials saved."
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
            _ = try keychainStore.saveInstagramCredentials(credentials)
            instagramCookieHeader = ""
            instagramStatus = .valid
            message = "Instagram credentials saved."
        } catch {
            instagramStatus = .serviceError("Could not save credentials")
            message = "Could not save Instagram credentials."
            return
        }

        do {
            let user = try await InstagramClient(credentialStore: keychainStore).verifiedUser()
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: String(user.pk),
                username: user.username,
                avatarURL: user.profilePicURL,
                status: .valid,
                enabledCategories: categories,
            )
            instagramEnabledCategories = categories
            instagramStatus = .valid
            message = "Instagram credentials saved."
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
        metadataStore.instagramAccount = nil
        instagramEnabledCategories = []
        instagramStoriesEnabled = true
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

    public func saveSpotifyCredentials(_ credentials: SpotifyCredentials) async {
        do {
            _ = try keychainStore.saveSpotifyCredentials(credentials)
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
            _ = try keychainStore.saveSpotifyCredentials(enriched)
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
            _ = try keychainStore.saveSpotifyCredentials(credentials)
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
        metadataStore.spotifyAccount = nil
        try? cacheStore.deleteNetwork(.spotify)
        spotifyStatus = .notConfigured
        message = "Spotify account disconnected."
    }

    public func disconnectDebug() {
        metadataStore.debugAccount = nil
        try? cacheStore.deleteNetwork(.debug)
        debugStatus = .notConfigured
        message = "Debug server disconnected."
    }

    public func loadStatuses() {
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
            instagramStatus = accountStatus(from: instagram.status)
        } else {
            instagramEnabledCategories = []
            instagramStoriesEnabled = true
            instagramStatus = .notConfigured
        }

        if let spotify = metadataStore.spotifyAccount {
            spotifyStatus = accountStatus(from: spotify.status)
        } else {
            spotifyStatus = .notConfigured
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
        case .serviceError: .serviceError("Invalid credentials")
        }
    }

    public func revalidateInstagram() async {
        guard metadataStore.instagramAccount != nil else { return }
        do {
            let client = InstagramClient(credentialStore: keychainStore)
            _ = try await client.verifiedUser()
            instagramStatus = .valid
            if var account = metadataStore.instagramAccount {
                account.status = .valid
                metadataStore.instagramAccount = account
            }
        } catch {
            instagramStatus = .invalidCredentials
            if var account = metadataStore.instagramAccount {
                account.status = .invalidCredentials
                metadataStore.instagramAccount = account
            }
        }
    }
}
