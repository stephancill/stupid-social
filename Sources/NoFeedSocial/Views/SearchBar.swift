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

    /// A search field pinned under the navigation bar in the screen's own content, for a root screen that's swiped
    /// back to: iOS draws the navigation-bar drawer's field without its capsule until an interactive pop finishes.
    func pinnedSearchBar(text: Binding<String>, prompt: String = "Search") -> some View {
        modifier(PinnedSearchBar(text: text, prompt: prompt))
    }
}

private struct PinnedSearchBar: ViewModifier {
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top) { field }
        } else {
            content.safeAreaInset(edge: .top) { field.background(.bar) }
        }
    }

    private var field: some View {
        let capsule = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)

        return Group {
            if #available(iOS 26.0, *) {
                capsule.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                capsule.background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
