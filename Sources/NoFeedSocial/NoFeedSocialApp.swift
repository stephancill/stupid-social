import NoFeedSocialCore
import SwiftData
import SwiftUI

@main
@MainActor
struct NoFeedSocialApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        AppMetrics.configure()
        do {
            // Kept out of the App Group: iOS kills a suspending app that holds a SQLite lock in a shared
            // container (0xdead10cc), and the notification extension never reads the cache.
            modelContainer = try ModelContainer(
                for: CachedNotification.self,
                configurations: ModelConfiguration(groupContainer: .none),
            )
        } catch {
            fatalError("Could not create SwiftData model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
