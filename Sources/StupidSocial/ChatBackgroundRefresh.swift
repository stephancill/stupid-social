import BackgroundTasks
import StupidSocialCore

/// Keeps chats current while the app isn't open: iOS wakes it about as often as it allows (no sooner than
/// `interval`), and it reloads the Chats list and loads changed chats ahead into the store, so they open on their
/// newest messages. Only a suspended app has its Chats list to do this; launched in the background from cold it
/// has none, and the task ends.
@MainActor
enum ChatBackgroundRefresh {
    static let identifier = "tech.stupid.StupidSocial.chatRefresh"
    private static let interval: TimeInterval = 15 * 60

    /// Before the app finishes launching, as `BGTaskScheduler` requires.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                run(task)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppMetrics.backgroundRefreshFailed(error)
        }
    }

    private static func run(_ task: BGTask) {
        schedule()
        guard let chatList = NotificationRouter.shared.chatList else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            await chatList.load()
            await chatList.loadAhead()
            AppMetrics.backgroundRefreshed()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
