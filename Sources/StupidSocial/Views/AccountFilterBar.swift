import StupidSocialCore
import SwiftUI

/// A pill that narrows a list (the feed, Chats): one account's items, or every chat reminder.
enum AccountFilter: Hashable {
    case account(String)
    case reminders
}

/// A Reminders pill, then one pill per account with items, most first. The list shows what any selected pill
/// matches.
struct AccountFilterBar: View {
    /// Accounts with items in the list, most first (ties keep the accounts' order), and any selected one so it
    /// can be turned off.
    static func accounts(_ accounts: [Account], itemAccountIds: [String], selection: Set<AccountFilter>) -> [Account] {
        let counts = itemAccountIds.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return accounts.enumerated()
            .filter { counts[$0.element.id] != nil || selection.contains(.account($0.element.id)) }
            .sorted { lhs, rhs in
                let lhsCount = counts[lhs.element.id, default: 0]
                let rhsCount = counts[rhs.element.id, default: 0]
                return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Accounts with items in the list, the one with the newest item first (ties keep the accounts' order), then any
    /// selected one without items, so it can be turned off. The feed's order: which network was last heard from.
    static func accountsByRecency(_ accounts: [Account], items: [(accountId: String, date: Date)], selection: Set<AccountFilter>) -> [Account] {
        let newest = items.reduce(into: [String: Date]()) { newest, item in
            newest[item.accountId] = max(newest[item.accountId] ?? item.date, item.date)
        }
        let withItems = accounts.enumerated()
            .filter { newest[$0.element.id] != nil }
            .sorted { lhs, rhs in
                let lhsDate = newest[lhs.element.id] ?? .distantPast
                let rhsDate = newest[rhs.element.id] ?? .distantPast
                return lhsDate != rhsDate ? lhsDate > rhsDate : lhs.offset < rhs.offset
            }
            .map(\.element)
        let selectedWithout = accounts.filter { newest[$0.id] == nil && selection.contains(.account($0.id)) }
        return withItems + selectedWithout
    }

    @ObservedObject var settingsViewModel: SettingsViewModel
    let accounts: [Account]
    let showsReminders: Bool
    @Binding var selection: Set<AccountFilter>
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        FilterPillBar(selection: $selection) {
            if showsReminders {
                FilterPill(filter: .reminders, selection: $selection) {
                    Image(systemName: "bell")
                        .frame(width: 16, height: 16)
                    Text("Reminders")
                }
            }
            ForEach(accounts) { account in
                FilterPill(filter: .account(account.id), selection: $selection) {
                    // Bluesky's blue butterfly would vanish on the selected pill's blue.
                    let isSelected = selection.contains(.account(account.id))
                    NetworkBadgeIcon(network: account.network, size: 16, tint: isSelected && account.network == .bluesky ? .white : nil)
                    Text(name(for: account))
                }
            }
        }
    }

    private func name(for account: Account) -> String {
        let name = settingsViewModel.name(for: account)
        return redactionEnabled && name.hasPrefix("@") ? "Redacted" : name
    }
}

/// One pill per network (Search's networks to search).
struct NetworkFilterBar: View {
    let networks: [SocialNetwork]
    @Binding var selection: Set<SocialNetwork>

    var body: some View {
        FilterPillBar(selection: $selection) {
            ForEach(networks, id: \.self) { network in
                FilterPill(filter: network, selection: $selection) {
                    NetworkBadgeIcon(network: network, size: 16, tint: selection.contains(network) && network == .bluesky ? .white : nil)
                        .accessibilityHidden(true)
                    Text(network.displayName)
                }
            }
        }
    }
}

/// A horizontally scrolling row of `FilterPill`s, led by a filter icon in a circle like the clear button's. While any
/// is selected, the clear button floats at the trailing edge, and the row scrolls far enough that the last pill clears
/// it.
///
/// A tap selects one pill in place of the others. A long press adds a pill to the selection instead, and from then on
/// taps add and remove pills, until the clear button (or turning the last one off) ends it. Meanwhile the clear
/// button carries a badge with how many are selected.
struct FilterPillBar<Filter: Hashable, Pills: View>: View {
    @Binding var selection: Set<Filter>
    @State private var isMultipleSelecting = false
    @ScaledMetric(relativeTo: .subheadline) private var clearButtonSize: CGFloat = 20
    /// The clear button's drawn width, including its style's padding, which the trailing margin makes room for.
    @State private var clearButtonWidth: CGFloat = 0

    @ViewBuilder let pills: () -> Pills
    private let edgeMargin: CGFloat = 16
    private let spacing: CGFloat = 8

    var body: some View {
        let isFiltering = !selection.isEmpty

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                filterIcon
                pills()
            }
            .environment(\.isMultipleFilterSelecting, $isMultipleSelecting)
        }
        .contentMargins(.leading, edgeMargin, for: .scrollContent)
        .contentMargins(.trailing, isFiltering ? edgeMargin + clearButtonWidth + spacing : edgeMargin, for: .scrollContent)
        .overlay(alignment: .trailing) {
            if isFiltering {
                clearButton
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { clearButtonWidth = $0 }
                    .padding(.trailing, edgeMargin)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: selection.count, initial: true) { _, count in
            // A selection of several kept from before is still one; an emptied one is single again.
            if count > 1 {
                isMultipleSelecting = true
            } else if count == 0 {
                isMultipleSelecting = false
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var clearButton: some View {
        styledClearButton
            .overlay(alignment: .topTrailing) {
                if isMultipleSelecting {
                    Text(selection.count, format: .number)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(isMultipleSelecting ? "\(selection.count) selected" : "")
    }

    private var styledClearButton: some View {
        circleButton(systemImage: "xmark") {
            selection = []
            isMultipleSelecting = false
        }
        .accessibilityLabel("Clear Filter")
    }

    /// Drawn as a button so its circle is the clear button's, size and glass alike; it does nothing.
    private var filterIcon: some View {
        circleButton(systemImage: "line.3.horizontal.decrease") {}
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A glass circle on an opaque backing, so it reads over a list scrolling beneath the bar (Chats).
    @ViewBuilder
    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: clearButtonSize, height: clearButtonSize)
        }
        .buttonBorderShape(.circle)
        if #available(iOS 26.0, *) {
            button.buttonStyle(StillGlassButtonStyle(shape: Circle())).background(Color(.systemBackground), in: Circle())
        } else {
            button.buttonStyle(.bordered).tint(.secondary).background(.background, in: Circle())
        }
    }
}

extension EnvironmentValues {
    /// Whether a `FilterPillBar`'s pills add to the selection rather than replace it, set by a long press.
    @Entry var isMultipleFilterSelecting: Binding<Bool> = .constant(false)
}

/// A pill that selects `filter` alone, or toggles it in the selection while its bar selects several, prominent while
/// selected. A long press starts selecting several, with this pill added.
struct FilterPill<Filter: Hashable, Label: View>: View {
    let filter: Filter
    @Binding var selection: Set<Filter>
    @ViewBuilder let label: () -> Label
    @Environment(\.isMultipleFilterSelecting) private var isMultipleSelecting
    /// When a long press last selected this pill. The button's action can also run as the press lifts, which would
    /// undo it, so a tap straight after is ignored; whether it runs varies, so a flag could swallow a later tap.
    @State private var longPressedAt: Date?
    @State private var longPressCount = 0

    var body: some View {
        let isSelected = selection.contains(filter)
        let button = Button {
            if let longPressedAt, Date().timeIntervalSince(longPressedAt) < 1 {
                return
            } else if isMultipleSelecting.wrappedValue {
                if isSelected {
                    selection.remove(filter)
                } else {
                    selection.insert(filter)
                }
            } else {
                selection = isSelected && selection.count == 1 ? [] : [filter]
            }
        } label: {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .font(.subheadline)
        }
        .buttonBorderShape(.capsule)
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            longPressedAt = Date()
            selectSeveral()
        })
        .sensoryFeedback(.selection, trigger: longPressCount)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select Several") { selectSeveral() }

        if #available(iOS 26.0, *) {
            // Glass, like the search field; on an opaque backing, since where the bar floats over a list (Chats) glass
            // alone showed the rows' text through the label.
            button
                .buttonStyle(StillGlassButtonStyle(shape: Capsule(), isProminent: isSelected))
                .background(Color(.systemBackground), in: Capsule())
        } else if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func selectSeveral() {
        isMultipleSelecting.wrappedValue = true
        selection.insert(filter)
        longPressCount += 1
    }
}

/// Glass that stays still under a finger: `.glass` and `.glassProminent` are interactive glass, which stretches and
/// follows a drag across the pills. Pressed, the label dims instead.
@available(iOS 26.0, *)
struct StillGlassButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, shape is Circle ? 6 : 12)
            .padding(.vertical, 6)
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .glassEffect(isProminent ? .regular.tint(.accentColor) : .regular, in: shape)
    }
}
