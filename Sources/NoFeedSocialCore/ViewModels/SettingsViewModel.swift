import Foundation

/// Settings: the account list, adding and reconnecting accounts, each account's preferences, and removing
/// accounts. Adding an account the store already has (same network identity) updates it instead.
@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var statuses: [String: AccountStatus] = [:]
    @Published public var message: String?
    @Published public private(set) var isWorking = false

    @Published public var xCookieHeader = ""
    @Published public var farcasterUsername = ""
    @Published public var instagramCookieHeader = ""
    @Published public var spotifyBearerToken = ""
    @Published public var spotifyClientToken = ""
    @Published public var spotifySpDC = ""
    @Published public var blueskyLoginHint = ""
    @Published public var githubCookieHeader = ""
    @Published public var debugServerURL = ""
    @Published public private(set) var debugStatus: AccountStatus = .notConfigured

    public let services: AccountServices
    private let farcasterClient: FarcasterClient
    private let cacheStore: NotificationCacheStore
    private let apronService: ApronService
    /// The account id an unfinished Bluesky sign-in saves its tokens under.
    private var pendingBlueskyAccountId: String?

    private var store: AccountStore {
        services.store
    }

    public init(services: AccountServices, farcasterClient: FarcasterClient, cacheStore: NotificationCacheStore, apronService: ApronService) {
        self.services = services
        self.farcasterClient = farcasterClient
        self.cacheStore = cacheStore
        self.apronService = apronService
        loadStatuses()
        for name in [AccountStore.didChangeNotification, AccountStore.statusDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.loadStatuses()
                }
            }
        }
    }

    // MARK: List

    public func loadStatuses() {
        accounts = store.accounts
        statuses = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, Self.accountStatus(store.status(id: $0.id) ?? .valid)) })
        if let debug = store.debugAccount {
            debugServerURL = debug.serverURL.absoluteString
            debugStatus = Self.accountStatus(debug.status)
        } else {
            debugStatus = .notConfigured
        }
    }

    public func account(id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func status(for accountId: String) -> AccountStatus {
        statuses[accountId] ?? .notConfigured
    }

    /// "@handle" or the account's name, or its status when it needs attention or has no name yet.
    public func connectionLabel(for account: Account) -> String {
        let status = status(for: account.id)
        if status == .invalidCredentials {
            return status.label
        }
        return account.label ?? status.label
    }

    public var hasInvalidCredentials: Bool {
        statuses.values.contains(.invalidCredentials)
    }

    public var debugConnectionLabel: String {
        store.debugAccount?.serverURL.absoluteString ?? debugStatus.label
    }

    private static func accountStatus(_ snapshot: AccountStatusSnapshot) -> AccountStatus {
        switch snapshot {
        case .valid: .valid
        case .invalidCredentials: .invalidCredentials
        case .iCloudUnavailable: .iCloudUnavailable
        case .notConfigured: .notConfigured
        case .networkUnavailable: .networkUnavailable
        case .serviceError: .serviceError("Validation failed")
        }
    }

    // MARK: Adding

    /// Who a new sign-in is, from the network.
    private struct Identity {
        var remoteId: String
        var handle: String?
        var displayName: String?
        var avatarURL: URL?
    }

    /// Saves credentials under a new account id (or the reconnected account's), asks the network who they
    /// belong to, and saves the account. When that identity is already listed, the credentials move to that
    /// account. Fails loudly, keeping nothing, when the network can't say who signed in.
    @discardableResult
    private func connect(
        _ network: SocialNetwork,
        reconnecting accountId: String?,
        save: (KeychainCredentialStore) throws -> Void,
        identify: (KeychainCredentialStore) async throws -> Identity,
    ) async -> Account? {
        isWorking = true
        defer { isWorking = false }
        let id = accountId ?? Account.newId(network: network)
        let credentials = services.keychain.scoped(to: id)
        do {
            try save(credentials)
        } catch {
            message = "Could not save \(network.displayName) credentials."
            return nil
        }
        let identity: Identity
        do {
            identity = try await identify(credentials)
        } catch SourceError.notConfigured {
            if accountId == nil {
                credentials.deleteAccountCredentials()
            } else {
                store.setStatus(.invalidCredentials, id: id)
            }
            message = "\(network.displayName) login expired. Log in again."
            return nil
        } catch {
            if accountId == nil {
                credentials.deleteAccountCredentials()
            }
            message = "Could not connect \(network.displayName): \(error.localizedDescription)"
            return nil
        }

        var account: Account
        if let existing = store.account(network: network, remoteId: identity.remoteId), existing.id != id {
            // The same account again: keep the listed one and give it these credentials.
            do {
                try save(services.keychain.scoped(to: existing.id))
            } catch {
                message = "Could not save \(network.displayName) credentials."
                return nil
            }
            credentials.deleteAccountCredentials()
            account = existing
        } else {
            account = store.account(id: id) ?? Account(id: id, network: network)
        }
        account.remoteId = identity.remoteId
        account.handle = identity.handle ?? account.handle
        account.displayName = identity.displayName ?? account.displayName
        account.avatarURL = identity.avatarURL ?? account.avatarURL
        store.setStatus(.valid, id: account.id)
        store.save(account)
        loadStatuses()
        message = accountId == nil ? "\(network.displayName) account added." : "\(network.displayName) account reconnected."
        if account.avatarURL == nil {
            await fillAvatar(account)
        }
        return account
    }

    /// The account's own profile picture, for its row in Settings.
    private func avatarURL(for account: Account) async -> URL? {
        let credentials = services.keychain.scoped(to: account.id)
        switch account.network {
        case .x:
            guard let handle = account.handle,
                  let image = try? await XClient(credentialStore: credentials).userProfile(screenName: handle).profileImageUrlHttps
            else { return nil }
            // `_normal` is 48 px; without the suffix X serves the original.
            return URL(string: image.replacingOccurrences(of: "_normal", with: ""))
        case .instagram:
            return try? await InstagramClient(credentialStore: credentials).currentUserProfile().profilePicURL
        case .bluesky:
            return try? await BlueskyClient(credentialStore: credentials).validateAccount().avatar
        case .farcaster:
            guard let handle = account.handle else { return nil }
            return try? await farcasterClient.user(byUsername: handle).pfpUrl
        case .spotify:
            guard let handle = account.handle,
                  let image = try? await SpotifyClient(credentialStore: credentials).userProfile(username: handle).images?.first?.url
            else { return nil }
            return URL(string: image)
        case .github:
            return account.handle.flatMap { URL(string: "https://github.com/\($0).png?size=96") }
        case .apron:
            return store.apronInfo(id: account.id)?.user?.avatarURL
        case .telegram:
            // A `tgfile:` URL, which loads through a signed-in Telegram client.
            return try? await services.component(id: account.id)?.telegramClient?.ownAvatarURL()
        case .debug:
            return nil
        }
    }

    private func fillAvatar(_ account: Account) async {
        guard let url = await avatarURL(for: account) else { return }
        store.update(id: account.id) { $0.avatarURL = url }
        loadStatuses()
    }

    @discardableResult
    public func addX(_ credentials: XCredentials, reconnecting accountId: String? = nil) async -> Account? {
        await connect(.x, reconnecting: accountId) { store in
            _ = try store.saveXCredentials(credentials)
        } identify: { store in
            let user = try await XClient(credentialStore: store).verifiedUser()
            return Identity(remoteId: user.idStr, handle: user.screenName, displayName: user.name)
        }
    }

    @discardableResult
    public func addXCookieHeader(reconnecting accountId: String? = nil) async -> Account? {
        guard let credentials = CookieHeaderParser.extractXCredentials(from: xCookieHeader) else {
            message = "X cookie header must include auth_token and ct0."
            return nil
        }
        xCookieHeader = ""
        return await addX(credentials, reconnecting: accountId)
    }

    @discardableResult
    public func addFarcaster() async -> Account? {
        let username = farcasterUsername.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("@")
        guard !username.isEmpty else {
            message = "Enter a Farcaster username."
            return nil
        }
        let account = await connect(.farcaster, reconnecting: nil) { _ in } identify: { [farcasterClient] _ in
            let user = try await farcasterClient.user(byUsername: String(username))
            return Identity(remoteId: String(user.fid), handle: user.username ?? String(username))
        }
        if account != nil {
            farcasterUsername = ""
        }
        return account
    }

    @discardableResult
    public func addInstagram(_ credentials: InstagramCredentials, reconnecting accountId: String? = nil) async -> Account? {
        await connect(.instagram, reconnecting: accountId) { store in
            _ = try store.saveInstagramCredentials(credentials)
        } identify: { store in
            let profile = try await InstagramClient(credentialStore: store).currentUserProfile()
            return Identity(remoteId: String(profile.pk), handle: profile.username, displayName: profile.fullName, avatarURL: profile.profilePicURL)
        }
    }

    @discardableResult
    public func addInstagramCookieHeader(reconnecting accountId: String? = nil) async -> Account? {
        guard let credentials = CookieHeaderParser.extractInstagramCredentials(from: instagramCookieHeader) else {
            message = "Instagram cookie header must include sessionid, csrftoken, and ds_user_id."
            return nil
        }
        instagramCookieHeader = ""
        return await addInstagram(credentials, reconnecting: accountId)
    }

    @discardableResult
    public func addSpotify(_ credentials: SpotifyCredentials, reconnecting accountId: String? = nil) async -> Account? {
        let account = await connect(.spotify, reconnecting: accountId) { store in
            _ = try store.saveSpotifyCredentials(credentials)
        } identify: { store in
            guard let username = try await SpotifyClient(credentialStore: store).validateAccount() else {
                throw SourceError.serviceError("Spotify didn't say which account signed in.")
            }
            return Identity(remoteId: username, handle: username)
        }
        if let account {
            await fetchSpotifyInitToken(credentials, store: services.keychain.scoped(to: account.id))
        }
        return account
    }

    @discardableResult
    public func addSpotifyManualCredentials() async -> Account? {
        let bearer = spotifyBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = spotifyClientToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let spDC = spotifySpDC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bearer.isEmpty, !client.isEmpty else {
            message = "Bearer token and client token are required."
            return nil
        }
        spotifyBearerToken = ""
        spotifyClientToken = ""
        spotifySpDC = ""
        return await addSpotify(SpotifyCredentials(bearerToken: bearer, clientToken: client, spDC: spDC, username: nil))
    }

    /// Best effort: the web player's init token, kept with the credentials.
    private func fetchSpotifyInitToken(_ creds: SpotifyCredentials, store: KeychainCredentialStore) async {
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

            let existing = try store.loadSpotifyCredentials() ?? creds
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
                clientId: decoded.clientId ?? existing.clientId,
            )
            _ = try store.saveSpotifyCredentials(enriched)
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

    public func beginBlueskyOAuth(reconnecting accountId: String? = nil) async throws -> BlueskyOAuthSession {
        let hint = blueskyLoginHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = accountId ?? Account.newId(network: .bluesky)
        pendingBlueskyAccountId = id
        return try await BlueskyClient(credentialStore: services.keychain.scoped(to: id)).startOAuth(loginHint: hint.isEmpty ? nil : hint)
    }

    @discardableResult
    public func finishBlueskyOAuth(callbackURL: URL, session: BlueskyOAuthSession) async -> Account? {
        guard let id = pendingBlueskyAccountId else { return nil }
        pendingBlueskyAccountId = nil
        let reconnecting = store.account(id: id) != nil ? id : nil
        var finished: BlueskyOAuthCredentials?
        let account = await connect(.bluesky, reconnecting: reconnecting) { store in
            // The OAuth exchange saves the tokens; moving to a listed account saves them there.
            if let finished {
                _ = try store.saveBlueskyCredentials(finished)
            }
        } identify: { store in
            let credentials = try await BlueskyClient(credentialStore: store).finishOAuth(callbackURL: callbackURL, session: session)
            finished = credentials
            return Identity(remoteId: credentials.did, handle: credentials.handle)
        }
        if account != nil {
            blueskyLoginHint = ""
        }
        return account
    }

    @discardableResult
    public func addGitHub(_ credentials: GitHubCredentials, reconnecting accountId: String? = nil) async -> Account? {
        var stored = credentials
        return await connect(.github, reconnecting: accountId) { store in
            _ = try store.saveGitHubCredentials(stored)
        } identify: { store in
            // The login WebView only sets a username when GitHub's `dotcom_user` cookie was captured during the
            // flow, which is unreliable. Resolve the signed-in account from the authenticated homepage.
            if stored.username?.isEmpty != false, let resolved = try await GitHubClient().authenticatedUser(credentials: stored) {
                stored = GitHubCredentials(
                    userSession: stored.userSession,
                    sameSiteUserSession: stored.sameSiteUserSession,
                    username: resolved,
                    additionalCookies: stored.additionalCookies,
                )
                _ = try store.saveGitHubCredentials(stored)
            }
            guard let username = stored.username, !username.isEmpty else {
                throw SourceError.serviceError("GitHub didn't say which account signed in.")
            }
            let result = try await GitHubClient().forYouFeed(credentials: stored)
            guard case let .feed(response) = result else { throw SourceError.notConfigured }
            _ = try GitHubActivityParser.parse(response.html)
            return Identity(remoteId: username, handle: username)
        }
    }

    @discardableResult
    public func addGitHubCookieHeader(reconnecting accountId: String? = nil) async -> Account? {
        guard let credentials = CookieHeaderParser.extractGitHubCredentials(from: githubCookieHeader) else {
            message = "GitHub cookie header must include user_session and __Host-user_session_same_site."
            return nil
        }
        githubCookieHeader = ""
        return await addGitHub(credentials, reconnecting: accountId)
    }

    /// A Telegram sign-in for a new account. Telegram sign-ins stay on this device, under the account's id.
    public func makeTelegramSignIn() -> TelegramConnectionViewModel {
        let id = Account.newId(network: .telegram)
        let client = TelegramClient(keychain: services.keychain.scoped(to: id))
        let viewModel = TelegramConnectionViewModel(client: client)
        viewModel.onSignIn = { [weak self] account in
            await self?.finishTelegramSignIn(account, accountId: id, client: client)
        }
        viewModel.onChange = { [weak services] in
            services?.onTelegramChange?()
        }
        return viewModel
    }

    /// Lists a Telegram account once it signed in on this device. An account already listed (from another
    /// device, or signed in before) gets this sign-in, which moves to its id.
    public func finishTelegramSignIn(_ telegram: TelegramAccount, accountId: String, client: TelegramClient) async {
        let remoteId = String(telegram.userId)
        var account: Account
        if let existing = store.account(network: .telegram, remoteId: remoteId), existing.id != accountId {
            await client.moveSession(to: services.keychain.scoped(to: existing.id))
            await services.component(id: existing.id)?.telegramClient?.reloadSession()
            account = existing
        } else {
            account = store.account(id: accountId) ?? Account(id: accountId, network: .telegram)
        }
        account.remoteId = remoteId
        account.handle = telegram.username
        account.displayName = telegram.name
        store.setStatus(.valid, id: account.id)
        store.save(account)
        // Built now, so registering for pushes right after finds the new account's client.
        _ = services.components(for: account)
        loadStatuses()
        if account.avatarURL == nil {
            await fillAvatar(account)
        }
    }

    /// Fills in identities missing from accounts that predate multi-account support (the X user id, an
    /// Instagram avatar, a Spotify username), so the same account added again is recognized.
    public func repairAccountIdentities() async {
        for account in store.accounts {
            let credentials = services.keychain.scoped(to: account.id)
            switch account.network {
            case .x where account.remoteId == nil:
                guard let user = try? await XClient(credentialStore: credentials).verifiedUser() else { continue }
                store.update(id: account.id) {
                    $0.remoteId = user.idStr
                    $0.handle = user.screenName
                    $0.displayName = user.name
                }
            case .instagram where account.handle?.isEmpty != false || account.avatarURL == nil:
                do {
                    let profile = try await InstagramClient(credentialStore: credentials).currentUserProfile()
                    store.update(id: account.id) {
                        $0.remoteId = String(profile.pk)
                        $0.handle = profile.username
                        $0.avatarURL = profile.profilePicURL
                    }
                } catch SourceError.notConfigured {
                    store.setStatus(.invalidCredentials, id: account.id)
                } catch {
                    continue
                }
            case .spotify where account.handle?.isEmpty != false:
                guard let username = try? await SpotifyClient(credentialStore: credentials).validateAccount() else { continue }
                store.update(id: account.id) {
                    $0.remoteId = username
                    $0.handle = username
                }
            default:
                break
            }
        }
        // Accounts added before rows showed avatars, or whose avatar came from another device's sign-in.
        for account in store.accounts where account.avatarURL == nil {
            await fillAvatar(account)
        }
        loadStatuses()
    }

    // MARK: Preferences

    private func updatePreferences(_ accountId: String, _ change: (inout AccountPreferences) -> Void) {
        store.update(id: accountId) { change(&$0.preferences) }
        loadStatuses()
    }

    public func xCategories(_ account: Account) -> Set<XNotificationCategory> {
        account.preferences.xCategories ?? Set(XNotificationCategory.allCases)
    }

    public func setXCategory(_ category: XNotificationCategory, enabled: Bool, accountId: String) {
        guard let account = account(id: accountId) else { return }
        var categories = xCategories(account)
        if enabled { categories.insert(category) } else { categories.remove(category) }
        updatePreferences(accountId) { $0.xCategories = categories }
    }

    public func farcasterCategories(_ account: Account) -> Set<FarcasterNotificationCategory> {
        account.preferences.farcasterCategories ?? Set(FarcasterNotificationCategory.allCases)
    }

    public func setFarcasterCategory(_ category: FarcasterNotificationCategory, enabled: Bool, accountId: String) {
        guard let account = account(id: accountId) else { return }
        var categories = farcasterCategories(account)
        if enabled { categories.insert(category) } else { categories.remove(category) }
        updatePreferences(accountId) { $0.farcasterCategories = categories }
    }

    public func instagramCategories(_ account: Account) -> Set<InstagramNotificationCategory> {
        account.preferences.instagramCategories ?? Set(InstagramNotificationCategory.allCases)
    }

    public func setInstagramCategory(_ category: InstagramNotificationCategory, enabled: Bool, accountId: String) {
        guard let account = account(id: accountId) else { return }
        var categories = instagramCategories(account)
        if enabled { categories.insert(category) } else { categories.remove(category) }
        updatePreferences(accountId) { $0.instagramCategories = categories }
    }

    public func setInstagramStories(enabled: Bool, accountId: String) {
        updatePreferences(accountId) { $0.instagramStoriesEnabled = enabled }
    }

    public func setInstagramDirectMediaShares(enabled: Bool, accountId: String) {
        updatePreferences(accountId) { $0.instagramDirectMediaSharesEnabled = enabled }
    }

    // MARK: Removing

    /// Removes the account from every device, with its credentials and cached items. Telegram signs out
    /// first so Telegram stops pushing to this device.
    public func remove(accountId: String) async {
        guard let account = store.account(id: accountId) else { return }
        switch account.network {
        case .apron:
            if let serverURL = account.serverURL {
                apronService.removeServer(serverURL: serverURL)
            }
        case .telegram:
            await services.component(id: accountId)?.telegramClient?.signOut()
        default:
            break
        }
        services.keychain.scoped(to: accountId).deleteAccountCredentials()
        try? cacheStore.deleteAccount(network: account.network, accountId: accountId)
        store.remove(id: accountId)
        loadStatuses()
        message = "\(account.network.displayName) account removed."
    }

    // MARK: Debug server

    public func saveDebugServerURL() {
        let value = debugServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "http" || url.scheme == "https" else {
            debugStatus = .serviceError("Invalid URL")
            message = "Enter an http or https debug server URL."
            return
        }
        store.debugAccount = DebugAccountMetadata(serverURL: url, status: .valid)
        debugStatus = .valid
        message = "Debug notifications server saved."
    }

    public func disconnectDebug() {
        store.debugAccount = nil
        try? cacheStore.deleteAccount(network: .debug, accountId: DebugNotificationSource.accountId)
        debugStatus = .notConfigured
        message = "Debug server disconnected."
    }
}
