import SwiftUI

extension View {
    /// The app's search field, shared by Search, Chats, the member lists and searching a chat. `.automatic` floats it
    /// at the bottom on iOS 26; `.navigationBarDrawer(displayMode: .always)` keeps it under the title.
    func searchBar(text: Binding<String>, prompt: String = "Search", placement: SearchFieldPlacement = .automatic) -> some View {
        searchable(text: text, placement: placement, prompt: prompt)
    }

    /// The same field, focused while `isPresented` is true and reporting when the user dismisses it.
    func searchBar(text: Binding<String>, isPresented: Binding<Bool>, prompt: String = "Search", placement: SearchFieldPlacement = .automatic) -> some View {
        searchable(text: text, isPresented: isPresented, placement: placement, prompt: prompt)
    }
}
