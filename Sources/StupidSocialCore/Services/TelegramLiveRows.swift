import Foundation
import OSLog

/// Keeps a Telegram account's Chats rows current while its session is open: after a burst of message updates for
/// any chat, the dialogs reload and replace the rows, so their latest messages change and the Chats list loads
/// the changed chats ahead (`ChatListViewModel.prefetcher`).
@MainActor
final class TelegramLiveRows {
    private let client: TelegramClient
    private let accountId: String
    private weak var chatList: ChatListViewModel?
    private var observer: UUID?
    private var reconnectObserver: UUID?
    private var reload: Task<Void, Never>?
    private var lastReload: Date = .distantPast
    /// Updates come in bursts; a busy account reloads the dialogs at most this often.
    private let interval: TimeInterval = 3
    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "TelegramLiveRows")

    init(client: TelegramClient, accountId: String, chatList: ChatListViewModel) {
        self.client = client
        self.accountId = accountId
        self.chatList = chatList
        Task {
            observer = await client.addMessageObserver { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
            // Messages that came while updates were missed change rows too.
            reconnectObserver = await client.addReconnectObserver { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
        }
    }

    private func scheduleReload() {
        // The session stays open in demo mode (sign-in, push registration), but its rows would join the preview chats.
        guard reload == nil, !DemoData.isDemoMode else { return }
        let wait = max(0.5, interval - Date().timeIntervalSince(lastReload))
        reload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            lastReload = Date()
            reload = nil
            do {
                let page = try await client.chatList()
                guard !DemoData.isDemoMode else { return }
                chatList?.updateChats(page.chats, accountId: accountId)
            } catch {
                logger.error("reload failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func stop() {
        reload?.cancel()
        for id in [observer, reconnectObserver].compactMap(\.self) {
            Task { [client] in await client.removeUpdateObserver(id) }
        }
        observer = nil
        reconnectObserver = nil
    }
}
