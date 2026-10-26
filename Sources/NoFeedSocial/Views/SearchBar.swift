import SwiftUI

extension View {
    /// The app's search field, shared by Search and Chats. `.automatic` floats it at the bottom on iOS 26;
    /// `.navigationBarDrawer(displayMode: .always)` keeps it under the title.
    func searchBar(text: Binding<String>, prompt: String = "Search", placement: SearchFieldPlacement = .automatic) -> some View {
        searchable(text: text, placement: placement, prompt: prompt)
    }
}
