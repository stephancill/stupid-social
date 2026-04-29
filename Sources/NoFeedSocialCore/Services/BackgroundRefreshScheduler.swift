import Foundation
import OSLog

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
#endif

public final class BackgroundRefreshScheduler {
    public static let taskIdentifier = "tech.stupid.StupidSocial.refresh"

    private let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "BackgroundRefresh")

    public init() {}

    public func register() {
        #if os(iOS) && canImport(BackgroundTasks)
        guard permittedIdentifiers.contains(Self.taskIdentifier) else {
            logger.info("Background refresh registration skipped because the task identifier is not in Info.plist")
            return
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handle(task: task)
        }
        #else
        logger.info("BackgroundTasks unavailable on this platform")
        #endif
    }

    public func schedule() {
        #if os(iOS) && canImport(BackgroundTasks)
        guard permittedIdentifiers.contains(Self.taskIdentifier) else {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Could not schedule background refresh")
        }
        #else
        logger.info("Background refresh scheduling skipped")
        #endif
    }

    #if os(iOS) && canImport(BackgroundTasks)
    private func handle(task: BGTask) {
        schedule()
        task.setTaskCompleted(success: true)
    }
    #endif

    private var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }
}
