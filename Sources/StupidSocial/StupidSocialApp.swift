import StupidSocialCore
import SwiftData
import SwiftUI

@main
@MainActor
struct StupidSocialApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        AppMetrics.configure()
        ChatKit.onEvent = AppMetrics.chat
        ChatKit.networkIcon = { network, size in AnyView(NetworkBadgeIcon(network: network, size: size)) }
        // Apron links open in the app, never in a browser.
        ChatKit.openAppLink = { url, contentServer in NotificationRouter.shared.open(url, contentServer: contentServer) }
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
