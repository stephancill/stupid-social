import Foundation

/// Unlocking X Chat: the user's XChat PIN recovers their private keys from X's Juicebox realms, once per Apple
/// account (the keys sync through iCloud Keychain).
@MainActor
public final class XChatUnlockViewModel: ObservableObject {
    @Published public private(set) var isUnlocked: Bool
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?
    @Published public var pin = ""

    private let client: XChatClient
    private let keychainStore: KeychainCredentialStore
    /// Called after unlocking or forgetting the keys, such as to reload the Chats list.
    public var onChange: (() -> Void)?

    public init(client: XChatClient, keychainStore: KeychainCredentialStore) {
        self.client = client
        self.keychainStore = keychainStore
        isUnlocked = keychainStore.hasXChatKeys()
    }

    public var canUnlock: Bool {
        !isWorking && !pin.isEmpty
    }

    /// Re-reads the keys, such as after disconnecting X deleted them.
    public func refresh() {
        let unlocked = keychainStore.hasXChatKeys()
        guard unlocked != isUnlocked else { return }
        isUnlocked = unlocked
        onChange?()
    }

    public func unlock() async {
        guard canUnlock else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await client.recoverKeys(pin: pin)
            pin = ""
            isUnlocked = true
            onChange?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func forgetKeys() async {
        do {
            try await client.forgetKeys()
            isUnlocked = false
            onChange?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
