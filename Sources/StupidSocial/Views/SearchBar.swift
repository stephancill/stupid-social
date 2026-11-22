import SwiftUI

extension View {
    /// The app's search field, shared by Search, Chats and searching a chat. `.automatic` floats it
    /// at the bottom on iOS 26; `.navigationBarDrawer(displayMode: .always)` keeps it under the title.
    /// On a Mac it's a plain field pinned under the title instead: see `PlainSearchField`.
    @ViewBuilder
    func searchBar(text: Binding<String>, prompt: String = "Search", placement: SearchFieldPlacement = .automatic) -> some View {
        if PlainSearchField.isNeeded {
            modifier(PlainSearchBar(field: PlainSearchField(text: text, prompt: prompt)))
        } else {
            searchable(text: text, placement: placement, prompt: prompt)
        }
    }

    /// The same field, focused while `isPresented` is true and reporting when the user dismisses it.
    @ViewBuilder
    func searchBar(text: Binding<String>, isPresented: Binding<Bool>, prompt: String = "Search", placement: SearchFieldPlacement = .automatic) -> some View {
        if PlainSearchField.isNeeded {
            modifier(PlainSearchBar(field: PlainSearchField(text: text, prompt: prompt, isPresented: isPresented)))
        } else {
            searchable(text: text, isPresented: isPresented, placement: placement, prompt: prompt)
        }
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

/// Pins the Mac's search field under the navigation bar, with the title inline: a large title stretches down with
/// the list when a trackpad overscrolls it, and slid under the pinned field.
private struct PlainSearchBar: ViewModifier {
    let field: PlainSearchField

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top) { field }
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { field.background(Color(.systemBackground)) }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The search field on a Mac. There, presenting the system search controller of a field in the navigation bar
/// throws on macOS 27 (observed 2026-11-17, 27.0.1): its layout asks `UINavigationBar` for its default size, which
/// reads the main screen's scene bounds, and for an app without multiple scenes UIKit looks those up through
/// screen-based focus, which raises "unsupported" when the app runs on a Mac. A plain text field never presents.
/// Temporary: try the system search field again with each new iOS/macOS release and remove this once it works.
struct PlainSearchField: View {
    static let isNeeded = ProcessInfo.processInfo.isiOSAppOnMac

    @Binding var text: String
    var prompt: String
    var isPresented: Binding<Bool>?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(.secondarySystemBackground), in: .capsule)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onChange(of: isPresented?.wrappedValue) { _, presented in
            if presented == true { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { isPresented?.wrappedValue = false }
        }
    }
}
