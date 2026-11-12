import Foundation
@testable import StupidSocialCore

/// An adapter run against a store of its own, as the chat screen runs it: pages and live updates go into the store,
/// and what it shows is the adapter's rendering of the newest stored messages.
@MainActor
final class StoredChat<Adapter: ChatAdapter> {
    let adapter: Adapter
    let store: ChatStore
    let chatKey: String

    init(_ adapter: Adapter) throws {
        self.adapter = adapter
        store = try ChatStore(url: FileManager.default.temporaryDirectory.appending(path: "StoredChat-\(UUID().uuidString).sqlite"))
        chatKey = "test|\(adapter.key)"
        adapter.history = ChatHistory(store: store, chatKey: chatKey)
    }

    func loadNewest() async throws {
        try await store.apply(adapter.fetch(.newest), for: .newest, chatKey: chatKey)
    }

    /// Stores a page, as fetching one would.
    func apply(_ page: ChatPage) throws {
        try store.apply(page, for: .newest, chatKey: chatKey)
    }

    func rendering() -> ChatRendering {
        adapter.render((try? store.window(chatKey: chatKey, at: .newest(count: 1000)).records) ?? [])
    }

    var messages: [ChatMessage] {
        rendering().messages
    }

    var reactions: [String: [ChatReaction]] {
        rendering().reactions
    }
}
