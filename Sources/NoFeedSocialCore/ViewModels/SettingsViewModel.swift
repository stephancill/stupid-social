import Foundation
import Security

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var xCookieHeader = ""
    @Published public var farcasterUsername = ""
    @Published public private(set) var xStatus: AccountStatus = .notConfigured
    @Published public private(set) var farcasterStatus: AccountStatus = .notConfigured
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

    public func saveXCookieHeader() {
        guard let credentials = CookieHeaderParser.extractXCredentials(from: xCookieHeader) else {
            xStatus = .invalidCredentials
            message = "X cookie header must include auth_token and ct0."
            return
        }

        do {
            _ = try keychainStore.saveXCredentials(credentials)
            metadataStore.xAccount = XAccountMetadata(accountId: "x", handle: nil, status: .valid)
            xCookieHeader = ""
            xStatus = .valid
            message = "X credentials saved."
        } catch {
            xStatus = .serviceError("Could not save credentials")
            message = "Could not save X credentials."
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

    private func loadStatuses() {
        xStatus = metadataStore.xAccount == nil ? .notConfigured : .valid
        if let farcaster = metadataStore.farcasterAccount {
            farcasterUsername = farcaster.username
            farcasterStatus = .valid
        } else {
            farcasterStatus = .notConfigured
        }
    }
}
