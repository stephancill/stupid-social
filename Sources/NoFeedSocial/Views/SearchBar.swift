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

    /// Keeps the navigation-bar drawer's search field on its plain fill when content scrolls under the bar. There
    /// iOS swaps the fill for glass, and an interactive swipe back to the screen shows the bar through a portal
    /// that doesn't draw glass, so the field lost its capsule until the pop finished.
    func searchBarKeepsFill() -> some View {
        background(SearchFieldFillKeeper().frame(width: 0, height: 0))
    }
}

private struct SearchFieldFillKeeper: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_: Controller, context _: Context) {}

    final class Controller: UIViewController {
        private var observation: NSKeyValueObservation?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            observeField()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            observeField()
        }

        private func observeField() {
            var controller: UIViewController? = parent
            while let current = controller, current.navigationItem.searchController == nil {
                controller = current.parent
            }
            guard let field = controller?.navigationItem.searchController?.searchBar.searchTextField,
                  observation == nil
            else { return }
            observation = field.observe(\.backgroundColor, options: [.initial, .new]) { field, _ in
                MainActor.assumeIsolated {
                    guard field.backgroundColor != .secondarySystemBackground else { return }
                    field.backgroundColor = .secondarySystemBackground
                }
            }
        }
    }
}
