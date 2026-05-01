import NoFeedSocialCore
import SwiftData
import SwiftUI

#if !os(macOS)
@main
@MainActor
struct NoFeedSocialApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: CachedNotification.self)
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
#endif
