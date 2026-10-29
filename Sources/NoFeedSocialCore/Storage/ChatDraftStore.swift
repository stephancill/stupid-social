import Foundation

/// Unsent composer text per chat, by `ChatViewModel.chatKey`, kept on this device so leaving a chat doesn't
/// lose it.
public final class ChatDraftStore {
    private let defaults: UserDefaults
    private let key = "chatDrafts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func draft(key chatKey: String) -> String {
        drafts[chatKey] ?? ""
    }

    /// Saves the chat's draft; an empty or whitespace-only one removes it.
    public func setDraft(_ text: String, key chatKey: String) {
        var drafts = drafts
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard drafts[chatKey] != value else { return }
        drafts[chatKey] = value
        defaults.set(drafts, forKey: key)
    }

    /// Removes the drafts of every chat whose key starts with `prefix`, such as an Apron server's rooms.
    public func removeDrafts(keyPrefix prefix: String) {
        defaults.set(drafts.filter { !$0.key.hasPrefix(prefix) }, forKey: key)
    }

    private var drafts: [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
