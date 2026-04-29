import NoFeedSocial
import NoFeedSocialCore
import SwiftData
import SwiftUI

@main
struct NoFeedSocialMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: CachedNotification.self)
    }
}
