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
    /// The room marked on screen, so its notifications aren't shown; `nil` while the chat isn't showing.
    @State private var openRoomId: String?

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
            openRoomId = room.roomId
        }
        // A new direct chat gets its room with the first message.
        .onReceive(room.$roomId) { roomId in
            if openRoomId != nil {
                openRoomId = roomId
            }
        }
        .onChange(of: openRoomId) { previous, current in
            if let previous, !previous.isEmpty {
                NotificationRouter.shared.roomDidClose(serverURL: room.serverURL, roomId: previous)
            }
            if let current, !current.isEmpty {
                NotificationRouter.shared.roomDidOpen(serverURL: room.serverURL, roomId: current)
            }
        }
        .task {
            if let profileUserId, !hasShownLinkedProfile {
                hasShownLinkedProfile = true
                profileUser = room.apronUser(for: ChatUser(id: profileUserId, name: nil, avatarURL: nil))
            }
        }
        .onDisappear {
            openRoomId = nil
        }
    }
}
