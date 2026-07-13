import NoFeedSocialCore
import SwiftData
import SwiftUI

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?

    public init() {}

    public var body: some View {
        Group {
            if let container {
                FeedView(
                    viewModel: container.feedViewModel,
                    storyViewModel: container.storyBarViewModel,
                    settingsViewModel: container.settingsViewModel,
                    spotifyClient: container.spotifyClient,
                )
            } else {
                ProgressView()
            }
        }
        .task {
            if container == nil {
                configureDependencies()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let container else { return }
            Task {
                let refreshed = await container.feedViewModel.refreshOnForegroundActivation()
                if refreshed {
                    await container.storyBarViewModel.fetchStoryBarContent()
                }
            }
        }
    }

    private func configureDependencies() {
        let appContainer = AppContainer(modelContext: modelContext)
        container = appContainer

        Task {
            await appContainer.storyBarViewModel.fetchStoryBarContent()
        }
    }
}
