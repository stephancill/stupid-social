import StupidSocialCore
import SwiftUI

/// The thread a post belongs to, loaded when shown: every post above it, then the post itself, whose row is
/// highlighted when there are posts above it. Until the thread arrives, it shows the post and the post it replies
/// to when the notification has it.
struct PostThreadSections: View {
    let parent: NotificationTarget?
    let parentDetails: NotificationTargetDetails?
    let isLoadingParentDetails: Bool
    let focal: NotificationTarget
    let focalDetails: NotificationTargetDetails?
    let isLoadingFocalDetails: Bool
    let network: SocialNetwork
    let fallbackActors: [NotificationActor]
    let engaging: (any PostEngaging)?
    let threads: any PostThreadLoading

    @State private var thread: PostThread?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if hasContext {
                VStack(spacing: 0) {
                    if let thread {
                        ForEach(Array(thread.ancestors.enumerated()), id: \.element.target.id) { index, post in
                            card(post, continuesThread: true, followsThread: index > 0)
                        }
                    } else if let parent {
                        PostCardView(
                            target: parent,
                            network: network,
                            fallbackActors: fallbackActors,
                            details: parentDetails,
                            isLoadingDetails: isLoadingParentDetails,
                            engaging: engaging,
                            continuesThread: true,
                        )
                    }
                }
                .modifier(ZeroRowInsets(edges: .bottom))
                .listRowSeparator(.hidden)
            }

            Group {
                if let post = thread?.focal {
                    card(post, continuesThread: false, followsThread: hasContext)
                } else {
                    PostCardView(
                        target: focal,
                        network: network,
                        fallbackActors: fallbackActors,
                        details: focalDetails,
                        isLoadingDetails: isLoadingFocalDetails,
                        engaging: engaging,
                        followsThread: hasContext,
                    )
                }
            }
            .modifier(ZeroRowInsets(edges: hasContext ? .top : []))
            .listRowSeparator(.hidden)
            .listRowBackground(hasContext ? highlight : nil)
        } header: {
            Text("Thread")
        } footer: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
        .task(id: focal.id) {
            await load()
        }
    }

    /// Whether posts show above the focal one, so it needs picking out.
    private var hasContext: Bool {
        if let thread { return !thread.ancestors.isEmpty }
        return parent != nil
    }

    private var highlight: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
            .overlay(Color.accentColor.opacity(0.1))
    }

    private func card(_ post: PostThread.Post, continuesThread: Bool, followsThread: Bool) -> some View {
        PostCardView(
            target: post.target,
            network: network,
            fallbackActors: fallbackActors,
            details: NotificationTargetDetails(likeCount: post.engagement?.likeCount, engagement: post.engagement),
            isLoadingDetails: false,
            engaging: engaging,
            continuesThread: continuesThread,
            followsThread: followsThread,
        )
    }

    private func load() async {
        errorMessage = nil
        do {
            thread = try await threads.fetchThread(postId: focal.id)
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn't load the thread: \(error.localizedDescription)"
        }
    }
}

/// Joins a thread's rows: no inset on the given edges, so the line between posts runs across the row boundary.
private struct ZeroRowInsets: ViewModifier {
    let edges: Edge.Set

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.listRowInsets(edges, 0)
        } else {
            content.listRowInsets(EdgeInsets(
                top: edges.contains(.top) ? 0 : 11,
                leading: 20,
                bottom: edges.contains(.bottom) ? 0 : 11,
                trailing: 20,
            ))
        }
    }
}
