import Foundation

/// Runs work that should finish even if the user leaves the app meanwhile, such as a refresh started as the app
/// opens. iOS keeps the app running for it in the background; when that time runs out the work is cancelled,
/// rather than frozen with requests that time out when the app comes back.
enum BackgroundActivity {
    @MainActor
    static func run<T: Sendable>(reason: String, operation: @escaping @MainActor () async -> T) async -> T {
        let task = Task { @MainActor in await operation() }
        // `performExpiringActivity` runs the block on a background queue and keeps the app running while it blocks;
        // it calls the block again with `expired` when the time is up.
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            guard !expired else {
                task.cancel()
                return
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await task.value
                done.signal()
            }
            done.wait()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
