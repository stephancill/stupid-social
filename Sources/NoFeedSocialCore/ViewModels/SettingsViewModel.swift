import Foundation
import Security

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var xCookieHeader = ""
    @Published public var farcasterUsername = ""
    @Published public var instagramCookieHeader = ""
    @Published public var debugServerURL = ""
    @Published public private(set) var xStatus: AccountStatus = .notConfigured
    @Published public private(set) var farcasterStatus: AccountStatus = .notConfigured
    @Published public private(set) var instagramStatus: AccountStatus = .notConfigured
    @Published public var instagramEnabledCategories: Set<InstagramNotificationCategory> = []
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
        cacheStore: NotificationCacheStore
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
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: user.screenName, status: .valid)
            xStatus = .valid
            message = "Connected as @\(user.screenName)."
        } catch {
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .valid)
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
                status: .valid
            )
            farcasterStatus = .valid
            message = "Farcaster account saved."
        } catch {
            farcasterStatus = .serviceError("Could not resolve username")
            message = "Could not resolve Farcaster username."
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
                status: .valid,
                enabledCategories: categories
            )
            instagramEnabledCategories = categories
            instagramStatus = .valid
            message = "Connected as @\(user.username)."
        } catch {
            let categories = Set(InstagramNotificationCategory.allCases)
            metadataStore.instagramAccount = InstagramAccountMetadata(
                accountId: "instagram",
                username: nil,
                status: .valid,
                enabledCategories: categories
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
        try? cacheStore.deleteNetwork(.x)
        xStatus = .notConfigured
        message = "X account disconnected."
    }

    public func disconnectFarcaster() {
        metadataStore.farcasterAccount = nil
        try? cacheStore.deleteNetwork(.farcaster)
        farcasterStatus = .notConfigured
        message = "Farcaster account disconnected."
    }

    public func disconnectInstagram() {
        try? keychainStore.deleteInstagramCredentials()
        metadataStore.instagramAccount = nil
        instagramEnabledCategories = []
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

    public func disconnectDebug() {
        metadataStore.debugAccount = nil
        try? cacheStore.deleteNetwork(.debug)
        debugStatus = .notConfigured
        message = "Debug server disconnected."
    }

    public func loadStatuses() {
        xStatus = metadataStore.xAccount == nil ? .notConfigured : .valid
        if let farcaster = metadataStore.farcasterAccount {
            farcasterUsername = farcaster.username
            farcasterStatus = .valid
        } else {
            farcasterStatus = .notConfigured
        }

        if let instagram = metadataStore.instagramAccount {
            instagramEnabledCategories = instagram.enabledCategories
            instagramStatus = .valid
        } else {
            instagramEnabledCategories = []
            instagramStatus = .notConfigured
        }

        if let debug = metadataStore.debugAccount {
            debugServerURL = debug.serverURL.absoluteString
            debugStatus = .valid
        } else {
            debugStatus = .notConfigured
        }
    }
}
