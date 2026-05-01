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
}

public final class KeychainCredentialStore {
    private let service: String
    private let fallbackStore: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "tech.stupid.StupidSocial.credentials",
        fallbackStore: UserDefaults = .standard
    ) {
        self.service = service
        self.fallbackStore = fallbackStore
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

    private func deleteForAccount(_ account: String) throws {
        for synchronizable in synchronizableCandidates {
            let query = baseQuery(account: account, synchronizable: synchronizable)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { continue }
        }
        fallbackStore.removeObject(forKey: fallbackKey(account: account))
    }

    private func save(data: Data, account: String) throws -> CredentialSaveResult {
        if preferredSynchronizable {
            do {
                try save(data: data, account: account, synchronizable: true)
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
        } catch _ as KeychainCredentialStoreError {
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
        for synchronizable in synchronizableCandidates {
            var query = baseQuery(account: account, synchronizable: synchronizable)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            if status == errSecItemNotFound { continue }
            if status == errSecSuccess {
                return item as? Data
            }
            // Continue to next candidate on any non-success error
        }

        return fallbackStore.data(forKey: fallbackKey(account: account))
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

    private var preferredSynchronizable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private var synchronizableCandidates: [Bool] {
        preferredSynchronizable ? [true, false] : [false, true]
    }

    private func fallbackKey(account: String) -> String {
        "\(service).\(account).localFallback"
    }
}
