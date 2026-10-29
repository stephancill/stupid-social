import NoFeedSocialCore
import SwiftUI

/// Chat detail for one Apron room: the shared chat with the room's members and profiles.
struct ApronChatView: View {
    @StateObject private var viewModel: AdapterChatViewModel<ApronChatAdapter>
    @State private var profileUser: ApronUser?
    @State private var showsMembers = false
    /// A member to show on opening, such as from a link.
    private let profileUserId: String?
    @State private var hasShownLinkedProfile = false

    init(viewModel: @autoclosure @escaping () -> AdapterChatViewModel<ApronChatAdapter>, profileUserId: String? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.profileUserId = profileUserId
    }

    /// The room's members and profiles, from the same connection as the chat.
    private var room: ApronRoomViewModel {
        viewModel.adapter.room
    }

    var body: some View {
        ChatView(
            viewModel: viewModel,
            onTitleTap: { showsMembers = true },
            showProfile: { profileUser = room.apronUser(for: $0) },
            // Members and profiles pushed on top read the chat's live state, so it stays connected for them.
            keepsConnection: showsMembers || profileUser != nil,
        )
        .navigationDestination(isPresented: $showsMembers) {
            ApronMembersView(viewModel: room)
        }
        .navigationDestination(item: $profileUser) { user in
            ApronProfileView(viewModel: room, user: user)
        }
        .onAppear {
            NotificationRouter.shared.roomDidOpen(serverURL: room.serverURL, roomId: room.roomId)
        }
        .task {
            if let profileUserId, !hasShownLinkedProfile {
                hasShownLinkedProfile = true
                profileUser = room.apronUser(for: ChatUser(id: profileUserId, name: nil, avatarURL: nil))
            }
        }
        .onDisappear {
            NotificationRouter.shared.roomDidClose(serverURL: room.serverURL, roomId: room.roomId)
        }
    }
}
