import Foundation

@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = [] {
        didSet { reloadAtNextReminder() }
    }

    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?

    private let feedService: FeedService

    public var service: FeedService {
        feedService
    }

    private var reminderObservers: [NSObjectProtocol] = []
    private var nextReminderReload: Task<Void, Never>?

    public init(feedService: FeedService) {
        self.feedService = feedService
        // Reminders are local, so the feed shows them as they're set, removed or come due, wherever the user is.
        reminderObservers = [ChatReminderStore.remindersDidChange, ChatReminderStore.reminderDidFire].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadCachedFeed() }
            }
        }
    }

    /// Reloads when the next reminder comes due, so it is in the feed then without waiting for its notification.
    private func reloadAtNextReminder() {
        nextReminderReload?.cancel()
        let now = Date()
        guard let next = ChatReminderStore.all().map(\.dueDate).filter({ $0 > now }).min() else { return }
        nextReminderReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.5))
            guard !Task.isCancelled else { return }
            self?.loadCachedFeed()
        }
    }

    public func loadCachedFeed() {
        do {
            items = try feedService.loadCachedFeed()
        } catch {
            errorMessage = "Could not load cached notifications."
        }
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard !isRefreshing, !isForegroundRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            items = try await feedService.manualRefresh()
            errorMessage = nil
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? "Refresh failed."
        } catch {
            errorMessage = "Refresh failed."
        }

        return true
    }

    @discardableResult
    public func refreshOnForegroundActivation() async -> Bool {
        // Reminders that came due in the background show straight away, not after the sources refresh.
        loadCachedFeed()
        guard !isRefreshing, !isForegroundRefreshing else { return false }
        isForegroundRefreshing = true
        defer { isForegroundRefreshing = false }

        do {
            try await feedService.foregroundActivationRefresh()
            items = try feedService.loadCachedFeed()
            errorMessage = nil
        } catch {
            errorMessage = "Foreground refresh failed."
        }

        return true
    }
}
