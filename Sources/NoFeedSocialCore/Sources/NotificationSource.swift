import Foundation

@MainActor
public protocol NotificationSource {
    var network: SocialNetwork { get }

    func validateAccount() async throws -> AccountStatus
    func fetchUnreadCount() async throws -> Int?
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
    func fetchProfile(id: String) async throws -> NetworkProfile
}

public enum SourceError: LocalizedError {
    case notConfigured
    case unsupported
    case endpointSpikeRequired
    case invalidResponse
    case serviceError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Account is not configured."
        case .unsupported: "This source capability is not supported."
        case .endpointSpikeRequired: "X endpoint discovery must be completed before this is implemented."
        case .invalidResponse: "The service returned an invalid response."
        case let .serviceError(message): message
        }
    }
}
