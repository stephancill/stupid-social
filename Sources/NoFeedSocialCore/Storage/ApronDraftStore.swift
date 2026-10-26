import Foundation

/// Unsent composer text per Apron room, kept on this device so leaving a chat doesn't lose it.
public final class ApronDraftStore {
    private let defaults: UserDefaults
    private let key = "apronDrafts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func draft(serverURL: URL, roomId: String) -> String {
        drafts[Self.key(serverURL: serverURL, roomId: roomId)] ?? ""
    }

    /// Saves the room's draft; an empty or whitespace-only one removes it.
    public func setDraft(_ text: String, serverURL: URL, roomId: String) {
        var drafts = drafts
        let key = Self.key(serverURL: serverURL, roomId: roomId)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard drafts[key] != value else { return }
        drafts[key] = value
        defaults.set(drafts, forKey: self.key)
    }

    public func removeServer(_ serverURL: URL) {
        let prefix = "\(serverURL.absoluteString)|"
        defaults.set(drafts.filter { !$0.key.hasPrefix(prefix) }, forKey: key)
    }

    private var drafts: [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func key(serverURL: URL, roomId: String) -> String {
        "\(serverURL.absoluteString)|\(roomId)"
    }
}
