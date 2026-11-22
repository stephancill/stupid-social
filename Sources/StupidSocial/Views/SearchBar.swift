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

    /// A search field of the app's own floating at the bottom, as in Messages, presented while `isPresented` is true,
    /// with `accessory` (filter pills) above it while `showsAccessory`. iOS 26's bottom search field (`.searchable`,
    /// `.automatic`) stayed under the keyboard inside the home pager, whose pages don't avoid the keyboard themselves.
    /// On a Mac it's the plain field pinned under the title, as `searchBar` is there.
    @ViewBuilder
    func bottomSearchBar(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: String,
        showsAccessory: Bool,
        @ViewBuilder accessory: () -> some View,
    ) -> some View {
        if PlainSearchField.isNeeded {
            searchBar(text: text, isPresented: isPresented, prompt: prompt)
                .overlay(alignment: .bottom) { if showsAccessory { accessory() } }
        } else if #available(iOS 26.0, *) {
            modifier(BottomSearchBar(text: text, isPresented: isPresented, prompt: prompt, showsAccessory: showsAccessory, accessory: accessory()))
        } else {
            searchable(text: text, isPresented: isPresented, prompt: prompt)
                .safeAreaInset(edge: .bottom, spacing: 0) { if showsAccessory { accessory() } }
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

/// The bottom search field and its accessory, docked on the keyboard by UIKit (`KeyboardDock`) so they move with
/// the keyboard's own animation. Laid out by SwiftUI from the home pager's keyboard inset, they moved at once, ahead of
/// the keyboard rising and after it fell, even inside a UIKit animation; a SwiftUI spring standing in for the
/// keyboard's curve lagged behind it. Floating over the list rather than in its safe area: as a `safeAreaBar`, the
/// rows' edge shadow also covered the accessory and changed in a single frame as the search ended. Like iOS's own
/// field there's no shadow behind them; the glass blurs what's under it. The list's content makes room for them, so
/// the last row can scroll clear.
@available(iOS 26.0, *)
private struct BottomSearchBar<Accessory: View>: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    let showsAccessory: Bool
    let accessory: Accessory
    @State private var fieldHeight: CGFloat = 0
    @State private var accessoryHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, fieldHeight + (showsAccessory ? accessoryHeight : 0), for: .scrollContent)
            .overlay {
                KeyboardDock(content: VStack(spacing: 0) {
                    if showsAccessory {
                        accessory
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { accessoryHeight = $0 }
                            .transition(.opacity)
                    }
                    BottomSearchField(text: $text, isPresented: $isPresented, prompt: prompt)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fieldHeight = $0 }
                }
                // The dock's hosting controller doesn't share this view's transactions.
                .animation(.smooth(duration: 0.3), value: showsAccessory))
                    .ignoresSafeArea(.container, edges: .bottom)
            }
    }
}

/// Keeps `content` just above the keyboard, or where iOS's own bottom search field rests while there's none (in the
/// home indicator's area), moving with the keyboard's own animation through `keyboardLayoutGuide`, as the chat
/// composer does. Touches anywhere else pass through.
private struct KeyboardDock<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context _: Context) -> Controller {
        Controller(content: content)
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.hosting.rootView = content
    }

    final class Controller: UIViewController {
        let hosting: UIHostingController<Content>

        init(content: Content) {
            hosting = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            view = PassthroughView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            hosting.sizingOptions = .intrinsicContentSize
            hosting.safeAreaRegions = []
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(hosting)
            view.addSubview(hosting.view)
            // As far down as both allow: 8 pt above the keyboard, and 28 pt above the screen's bottom edge, which is
            // where iOS 26's bottom search field rests (measured on iOS 27.0).
            view.keyboardLayoutGuide.usesBottomSafeArea = false
            let resting = hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28)
            resting.priority = .defaultHigh
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosting.view.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
                hosting.view.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28),
                resting,
            ])
            hosting.didMove(toParent: self)
        }
    }

    /// Only the docked content takes touches.
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }
}

/// The bottom search field: a glass capsule, and while the search is presented, a glass button that ends it. Focusing
/// the field presents the search; it stays presented when the keyboard goes (scrolling the list), until the button.
@available(iOS 26.0, *)
private struct BottomSearchField: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                TextField(prompt, text: $text)
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
                    .accessibilityLabel("Clear Text")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: height)
            .contentShape(.capsule)
            .onTapGesture { isFocused = true }
            .glassEffect(.regular, in: .capsule)

            if isPresented {
                Button {
                    text = ""
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: height, height: height)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("Close")
                .transition(.scale.combined(with: .opacity))
            }
        }
        // iOS 26's bottom search field's margins (measured on iOS 27.0).
        .padding(.horizontal, 28)
        .animation(.smooth(duration: 0.3), value: isPresented)
        .onChange(of: isFocused) { _, focused in
            if focused { isPresented = true }
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            isFocused = presented
        }
    }
}
