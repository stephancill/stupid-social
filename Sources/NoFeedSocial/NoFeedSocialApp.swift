import NoFeedSocialCore
import SwiftData
import SwiftUI

#if !os(macOS)
@main
struct NoFeedSocialApp: App {
    private let backgroundRefreshScheduler = BackgroundRefreshScheduler()

    init() {
        backgroundRefreshScheduler.register()
        backgroundRefreshScheduler.schedule()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: CachedNotification.self)
    }
}
#endif
