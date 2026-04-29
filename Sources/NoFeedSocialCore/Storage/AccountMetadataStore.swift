import Foundation

public struct XAccountMetadata: Codable, Equatable {
    public var accountId: String
    public var handle: String?
    public var status: AccountStatusSnapshot

    public init(accountId: String, handle: String?, status: AccountStatusSnapshot) {
        self.accountId = accountId
        self.handle = handle
        self.status = status
    }
}

public struct FarcasterAccountMetadata: Codable, Equatable {
    public var username: String
    public var fid: UInt64
    public var status: AccountStatusSnapshot

    public init(username: String, fid: UInt64, status: AccountStatusSnapshot) {
        self.username = username
        self.fid = fid
        self.status = status
    }
}

public enum AccountStatusSnapshot: String, Codable, Equatable {
    case notConfigured
    case valid
    case invalidCredentials
    case iCloudUnavailable
    case networkUnavailable
    case serviceError
}

public final class AccountMetadataStore {
    private enum Key {
        static let xAccount = "account.x"
        static let farcasterAccount = "account.farcaster"
    }

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var xAccount: XAccountMetadata? {
        get { load(XAccountMetadata.self, key: Key.xAccount) }
        set { save(newValue, key: Key.xAccount) }
    }

    public var farcasterAccount: FarcasterAccountMetadata? {
        get { load(FarcasterAccountMetadata.self, key: Key.farcasterAccount) }
        set { save(newValue, key: Key.farcasterAccount) }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
