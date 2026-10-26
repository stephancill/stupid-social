import SwiftUI

extension View {
    /// The tighter row insets shared by the feed and Chats lists.
    func compactListRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}
