import BackgroundTasks
import os
import StupidSocialCore

/// Shows a phone-number link's progress in the system's UI while the user is in WhatsApp (iOS 26), and keeps the
/// app running past ordinary background time when iOS allows it. iOS ends it as soon as WhatsApp's camera is on, and
/// WhatsApp's code entry sits over its camera, so it usually ends early; the link itself relies on the view model's
/// ordinary background time, and this task's end doesn't cancel it.
///
/// Each link submits its own identifier under the `whatsappLink.*` wildcard in Info.plist, registering its handler
/// just before submitting: registering one handler for the wildcard doesn't match the submitted identifiers, and
/// registering an identifier twice ends the app.
@available(iOS 26.0, *)
@MainActor
final class WhatsAppLinkBackgroundTask {
    enum Stage {
        /// The code is showing; the user is typing it into WhatsApp.
        case code
        /// WhatsApp accepted the code; the link finishes and the device logs in.
        case finishing
    }

    private static let prefix = "tech.stupid.StupidSocial.whatsappLink."
    private static let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "WhatsAppLink")
    /// Progress while waiting for the code ticks toward this share of the total, so the task keeps reporting.
    private static let codeWaitShare: Int64 = 40
    private static let total: Int64 = 100

    private var task: BGContinuedProcessingTask?
    private var stage = Stage.code
    private var completed: Bool?
    private var ticker: Task<Void, Never>?

    /// Submits the task; nil when iOS won't run it now, in which case the link still works while the app is open.
    static func begin() -> WhatsAppLinkBackgroundTask? {
        let identifier = prefix + UUID().uuidString
        let activity = WhatsAppLinkBackgroundTask()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak activity] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let activity else {
                    task.setTaskCompleted(success: false)
                    return
                }
                activity.run(task)
            }
        }
        guard registered else {
            logger.error("Couldn't register the WhatsApp link task")
            return nil
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Linking WhatsApp", subtitle: "Enter the code in WhatsApp")
        // A link can't wait for later: the code expires.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppMetrics.whatsAppFailed("link_background_task", error: error)
            return nil
        }
        return activity
    }

    func advance(to stage: Stage) {
        self.stage = stage
        update()
    }

    func finish(success: Bool) {
        guard completed == nil else { return }
        completed = success
        ticker?.cancel()
        guard let task else { return }
        if success {
            task.progress.completedUnitCount = Self.total
        }
        task.setTaskCompleted(success: success)
    }

    private func run(_ task: BGContinuedProcessingTask) {
        if let completed {
            // The link ended before iOS started the task.
            task.setTaskCompleted(success: completed)
            return
        }
        self.task = task
        task.progress.totalUnitCount = Self.total
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.completed == nil else { return }
                self.completed = false
                self.ticker?.cancel()
            }
        }
        update()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.tick()
            }
        }
    }

    private func update() {
        guard let task, completed == nil else { return }
        switch stage {
        case .code:
            task.updateTitle("Linking WhatsApp", subtitle: "Enter the code in WhatsApp")
            task.progress.completedUnitCount = max(task.progress.completedUnitCount, 5)
        case .finishing:
            task.updateTitle("Linking WhatsApp", subtitle: "Finishing…")
            task.progress.completedUnitCount = max(task.progress.completedUnitCount, Self.codeWaitShare + 10)
        }
    }

    /// The system ends continued processing tasks that stop reporting progress, and waiting for the user to type
    /// the code reports none, so time spent waiting moves the bar a little, short of the next stage.
    private func tick() {
        guard let task, completed == nil else { return }
        let ceiling = stage == .code ? Self.codeWaitShare : Self.total - 5
        if task.progress.completedUnitCount < ceiling {
            task.progress.completedUnitCount += 1
        }
    }
}
