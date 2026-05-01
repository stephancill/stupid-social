import Foundation
import Security

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var xCookieHeader = ""
    @Published public var farcasterUsername = ""
    @Published public var debugServerURL = ""
    @Published public private(set) var xStatus: AccountStatus = .notConfigured
    @Published public private(set) var farcasterStatus: AccountStatus = .notConfigured
    @Published public private(set) var debugStatus: AccountStatus = .notConfigured
    @Published public var message: String?

    private let keychainStore: KeychainCredentialStore
    private let metadataStore: AccountMetadataStore
    private let farcasterClient: FarcasterClient

    public init(
        keychainStore: KeychainCredentialStore,
        metadataStore: AccountMetadataStore,
        farcasterClient: FarcasterClient
    ) {
        self.keychainStore = keychainStore
        self.metadataStore = metadataStore
        self.farcasterClient = farcasterClient
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

    public func loadStatuses() {
        xStatus = metadataStore.xAccount == nil ? .notConfigured : .valid
        if let farcaster = metadataStore.farcasterAccount {
            farcasterUsername = farcaster.username
            farcasterStatus = .valid
        } else {
            farcasterStatus = .notConfigured
        }

        if let debug = metadataStore.debugAccount {
            debugServerURL = debug.serverURL.absoluteString
            debugStatus = .valid
        } else {
            debugStatus = .notConfigured
        }
    }
}
