import NoFeedSocialCore
import SwiftData
import SwiftUI

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
