import Foundation

/// A Telegram profile, opened from a mention, a sender's avatar or a group's member list. `target` is what the
/// chat knows the person by: their user id, or `@username` for a mention whose user it hasn't loaded.
@MainActor
public final class TelegramProfileViewModel: ObservableObject {
    /// `nil` while loading.
    @Published public private(set) var profile: TelegramProfile?
    @Published public private(set) var errorMessage: String?

    private let client: TelegramClient
    public let target: String

    public init(client: TelegramClient, target: String) {
        self.client = client
        self.target = target
    }

    public func load() async {
        errorMessage = nil
        do {
            profile = switch Self.parse(target) {
            case let .user(id): try await client.profile(userId: id)
            case let .username(username): try await client.profile(username: username)
            case nil: throw TelegramError.unknownUser
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum Target: Equatable {
        case user(Int64)
        case username(String)
    }

    /// A sender's id is the user id, or the chat's key (`user:…`) when a message names no sender; a mention's is
    /// the user id or `@username`. Others, such as a channel posting in a group, have no profile.
    nonisolated static func parse(_ target: String) -> Target? {
        if target.hasPrefix("@") {
            let username = String(target.dropFirst())
            return username.isEmpty ? nil : .username(username)
        }
        if target.hasPrefix("user:") {
            return Int64(target.dropFirst("user:".count)).map(Target.user)
        }
        return Int64(target).map(Target.user)
    }
}

public extension TelegramMembersViewModel {
    /// The profile of someone in this chat, by the id its messages or mentions give them.
    func profile(for target: String) -> TelegramProfileViewModel {
        TelegramProfileViewModel(client: client, target: target)
    }
}
