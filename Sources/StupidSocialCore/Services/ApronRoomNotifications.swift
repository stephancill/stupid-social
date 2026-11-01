import Foundation

/// What a room notifies about on this account: every message, mentions and replies, or nothing.
public enum ApronNotificationLevel: String, CaseIterable, Sendable {
    case all
    case mentions
    case none

    public var label: String {
        switch self {
        case .all: "All Messages"
        case .mentions: "Mentions Only"
        case .none: "None"
        }
    }
}

/// Maps a room's notification level onto Apron push (§4.9.4). The app registers every device to wake for
/// `mentions`, `replies` and `private` (private rooms such as DMs), so rooms start at mentions only and private
/// rooms at every message. `None` is a room `mute` (§4.5.3), which every server with `status` keeps.
///
/// Raising a room to every message, or lowering a private room to mentions only, needs per-room wake scopes,
/// which the protocol doesn't have yet. The proposal: servers advertise `server.push.room_wake: true` and take
/// `status` `{room_id, wake}`, where `wake` lists the scopes that room wakes for in place of the registration's,
/// and `null` clears it; they send room `wake`s at sign-in like mutes. Until a server advertises it, those
/// levels aren't offered.
public struct ApronRoomNotifications: Equatable, Sendable {
    public static let registrationWake = ["mentions", "replies", "private"]
    static let allScopes = ["joined", "mentions", "replies"]
    static let mentionScopes = ["mentions", "replies"]

    public let isPrivate: Bool
    public let isMuted: Bool
    public let roomWake: [String]?
    /// The server's `wake` scopes (§4.9.4).
    public let serverWake: [String]
    public let supportsRoomWake: Bool
    /// Whether the server takes `status` mutes (§4.5).
    public let supportsMute: Bool

    public init(isPrivate: Bool, isMuted: Bool, roomWake: [String]?, serverWake: [String], supportsRoomWake: Bool, supportsMute: Bool) {
        self.isPrivate = isPrivate
        self.isMuted = isMuted
        self.roomWake = roomWake
        self.serverWake = serverWake
        self.supportsRoomWake = supportsRoomWake
        self.supportsMute = supportsMute
    }

    /// Whether a new message in this room wakes the device without a room setting.
    private var wakesForEveryMessageByDefault: Bool {
        isPrivate && serverWake.contains("private")
    }

    public var level: ApronNotificationLevel {
        if isMuted { return .none }
        if let roomWake { return roomWake.contains("joined") ? .all : .mentions }
        return wakesForEveryMessageByDefault ? .all : .mentions
    }

    public var options: [ApronNotificationLevel] {
        var options: [ApronNotificationLevel] = []
        if wakesForEveryMessageByDefault || supportsRoomWake {
            options.append(.all)
        }
        if !wakesForEveryMessageByDefault || supportsRoomWake {
            options.append(.mentions)
        }
        if supportsMute {
            options.append(.none)
        }
        return options
    }

    /// The `status` changes that set `level`, in order: unmute first, so a room is never left silent by a
    /// change that fails halfway.
    public func changes(to level: ApronNotificationLevel) -> [Change] {
        var changes: [Change] = []
        if level == .none {
            return isMuted ? [] : [.mute(true)]
        }
        if isMuted {
            changes.append(.mute(false))
        }
        let wantsEveryMessage = level == .all
        let scopes: [String]? = wantsEveryMessage == wakesForEveryMessageByDefault ? nil : (wantsEveryMessage ? Self.allScopes : Self.mentionScopes)
        if scopes != roomWake {
            changes.append(.wake(scopes))
        }
        return changes
    }

    public enum Change: Equatable, Sendable {
        case mute(Bool)
        case wake([String]?)
    }
}
