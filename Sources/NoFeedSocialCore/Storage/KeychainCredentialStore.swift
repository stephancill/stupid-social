import Foundation
import Security

public enum KeychainCredentialStoreError: LocalizedError {
    case encodeFailed
    case decodeFailed
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed:
            "Could not encode credentials."
        case .decodeFailed:
            "Could not decode credentials."
        case let .unhandledStatus(status):
            "Keychain error \(status)."
        }
    }

    var status: OSStatus? {
        if case let .unhandledStatus(status) = self { status } else { nil }
    }
}

public enum CredentialSaveResult: Equatable {
    case synced
    case localOnly

    public var label: String {
        switch self {
        case .synced: "iCloud"
        case .localOnly: "This device"
        }
    }
}

public final class KeychainCredentialStore {
    private struct StoredItem {
        let data: Data
        let modifiedAt: Date
    }

    private let service: String
    private let fallbackStore: UserDefaults
    private let prefersSynchronizable: Bool
    private let allowsInsecureFallback: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "tech.stupid.StupidSocial.credentials",
        fallbackStore: UserDefaults = .standard,
        prefersSynchronizable: Bool? = nil,
        allowsInsecureFallback: Bool? = nil,
    ) {
        self.service = service
        self.fallbackStore = fallbackStore
        #if targetEnvironment(simulator)
            self.prefersSynchronizable = prefersSynchronizable ?? false
            self.allowsInsecureFallback = allowsInsecureFallback ?? true
        #else
            self.prefersSynchronizable = prefersSynchronizable ?? true
            self.allowsInsecureFallback = allowsInsecureFallback ?? false
        #endif
    }

    public func saveXCredentials(_ credentials: XCredentials) throws -> CredentialSaveResult {
        let data = try encoder.encode(credentials)
        return try save(data: data, account: "x")
    }

    public func loadXCredentials() throws -> XCredentials? {
        guard let data = try load(account: "x") else { return nil }
        return try decoder.decode(XCredentials.self, from: data)
    }

    public func deleteXCredentials() throws {
        try deleteForAccount("x")
    }

    public func saveInstagramCredentials(_ credentials: InstagramCredentials) throws -> CredentialSaveResult {
        let data = try encoder.encode(credentials)
        return try save(data: data, account: "instagram")
    }

    public func loadInstagramCredentials() throws -> InstagramCredentials? {
        guard let data = try load(account: "instagram") else { return nil }
        return try decoder.decode(InstagramCredentials.self, from: data)
    }

    public func deleteInstagramCredentials() throws {
        try deleteForAccount("instagram")
    }

    public func saveSpotifyCredentials(_ credentials: SpotifyCredentials) throws -> CredentialSaveResult {
        let data = try encoder.encode(credentials)
        return try save(data: data, account: "spotify")
    }

    public func loadSpotifyCredentials() throws -> SpotifyCredentials? {
        guard let data = try load(account: "spotify") else { return nil }
        return try decoder.decode(SpotifyCredentials.self, from: data)
    }

    public func deleteSpotifyCredentials() throws {
        try deleteForAccount("spotify")
    }

    public func saveBlueskyCredentials(_ credentials: BlueskyOAuthCredentials) throws -> CredentialSaveResult {
        let data = try encoder.encode(credentials)
        return try save(data: data, account: "bluesky")
    }

    public func loadBlueskyCredentials() throws -> BlueskyOAuthCredentials? {
        guard let data = try load(account: "bluesky") else { return nil }
        return try decoder.decode(BlueskyOAuthCredentials.self, from: data)
    }

    public func deleteBlueskyCredentials() throws {
        try deleteForAccount("bluesky")
    }

    public func xCredentialStorage() throws -> CredentialSaveResult? {
        try storage(account: "x")
    }

    public func instagramCredentialStorage() throws -> CredentialSaveResult? {
        try storage(account: "instagram")
    }

    public func spotifyCredentialStorage() throws -> CredentialSaveResult? {
        try storage(account: "spotify")
    }

    public func blueskyCredentialStorage() throws -> CredentialSaveResult? {
        try storage(account: "bluesky")
    }

    private func deleteForAccount(_ account: String) throws {
        for synchronizable in [true, false] {
            let query = baseQuery(account: account, synchronizable: synchronizable)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { continue }
        }
        fallbackStore.removeObject(forKey: fallbackKey(account: account))
    }

    private func save(data: Data, account: String) throws -> CredentialSaveResult {
        if prefersSynchronizable {
            do {
                try save(data: data, account: account, synchronizable: true)
                try? delete(account: account, synchronizable: false)
                fallbackStore.removeObject(forKey: fallbackKey(account: account))
                return .synced
            } catch _ as KeychainCredentialStoreError {
                // Fall through to local-only storage below.
            }
        }

        do {
            try save(data: data, account: account, synchronizable: false)
            fallbackStore.removeObject(forKey: fallbackKey(account: account))
            return .localOnly
        } catch let error as KeychainCredentialStoreError {
            guard allowsInsecureFallback else { throw error }
            fallbackStore.set(data, forKey: fallbackKey(account: account))
            return .localOnly
        }
    }

    private func save(data: Data, account: String, synchronizable: Bool) throws {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unhandledStatus(status)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.unhandledStatus(addStatus)
        }
    }

    private func delete(account: String, synchronizable: Bool) throws {
        let query = baseQuery(account: account, synchronizable: synchronizable)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unhandledStatus(status)
        }
    }

    private func load(account: String) throws -> Data? {
        let synchronized = try? load(account: account, synchronizable: true)
        let local = try? load(account: account, synchronizable: false)

        if let local, local.modifiedAt > (synchronized?.modifiedAt ?? .distantPast) {
            if prefersSynchronizable,
               (try? save(data: local.data, account: account, synchronizable: true)) != nil
            {
                try? delete(account: account, synchronizable: false)
                fallbackStore.removeObject(forKey: fallbackKey(account: account))
            }
            return local.data
        }

        if let synchronized {
            try? delete(account: account, synchronizable: false)
            fallbackStore.removeObject(forKey: fallbackKey(account: account))
            return synchronized.data
        }

        if let local {
            if prefersSynchronizable,
               (try? save(data: local.data, account: account, synchronizable: true)) != nil
            {
                try? delete(account: account, synchronizable: false)
                fallbackStore.removeObject(forKey: fallbackKey(account: account))
            }
            return local.data
        }

        guard let legacy = fallbackStore.data(forKey: fallbackKey(account: account)) else { return nil }
        if prefersSynchronizable,
           (try? save(data: legacy, account: account, synchronizable: true)) != nil
        {
            fallbackStore.removeObject(forKey: fallbackKey(account: account))
        } else if (try? save(data: legacy, account: account, synchronizable: false)) != nil {
            fallbackStore.removeObject(forKey: fallbackKey(account: account))
        }
        return legacy
    }

    private func load(account: String, synchronizable: Bool) throws -> StoredItem? {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unhandledStatus(status)
        }
        guard let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else {
            throw KeychainCredentialStoreError.decodeFailed
        }
        return StoredItem(
            data: data,
            modifiedAt: attributes[kSecAttrModificationDate as String] as? Date ?? .distantPast,
        )
    }

    private func storage(account: String) throws -> CredentialSaveResult? {
        if (try? load(account: account, synchronizable: true)) != nil {
            return .synced
        }
        if (try? load(account: account, synchronizable: false)) != nil
            || fallbackStore.data(forKey: fallbackKey(account: account)) != nil
        {
            return .localOnly
        }
        return nil
    }

    private func baseQuery(account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse

        return query
    }

    private func fallbackKey(account: String) -> String {
        "\(service).\(account).localFallback"
    }
}
