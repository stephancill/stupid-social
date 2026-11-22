import StupidSocialCore
import SwiftUI

/// A pill that narrows a list (the feed, Chats): one account's items, or every chat reminder.
enum AccountFilter: Hashable {
    case account(String)
    case reminders
}

/// A Reminders pill, then one pill per account with items, most first. The list shows what any selected pill
/// matches. While any is selected, a clear button floats at the trailing edge, and the row scrolls far enough
/// that the last pill clears it.
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

    @ObservedObject var settingsViewModel: SettingsViewModel
    let accounts: [Account]
    let showsReminders: Bool
    @Binding var selection: Set<AccountFilter>
    /// Floating over a list that scrolls beneath it (Chats), where see-through bordered pills would be illegible:
    /// the pills are glass on an opaque backing instead, and the filter icon, with nothing behind it, is left out.
    var isFloating = false
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @ScaledMetric(relativeTo: .subheadline) private var clearButtonSize: CGFloat = 20
    /// The clear button's drawn width, including its style's padding, which the trailing margin makes room for.
    @State private var clearButtonWidth: CGFloat = 0

    private let edgeMargin: CGFloat = 16
    private let spacing: CGFloat = 8

    var body: some View {
        let isFiltering = !selection.isEmpty

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                if !isFloating {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                if showsReminders {
                    pill(for: .reminders) {
                        Image(systemName: "bell")
                            .frame(width: 16, height: 16)
                        Text("Reminders")
                    }
                }
                ForEach(accounts) { account in
                    pill(for: .account(account.id)) {
                        // Bluesky's blue butterfly would vanish on the selected pill's blue.
                        let isSelected = selection.contains(.account(account.id))
                        NetworkBadgeIcon(network: account.network, size: 16, tint: isSelected && account.network == .bluesky ? .white : nil)
                        Text(name(for: account))
                    }
                }
            }
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
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func pill(for filter: AccountFilter, @ViewBuilder label: () -> some View) -> some View {
        let isSelected = selection.contains(filter)
        let button = Button {
            if isSelected {
                selection.remove(filter)
            } else {
                selection.insert(filter)
            }
        } label: {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .font(.subheadline)
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if #available(iOS 26.0, *), isFloating {
            // Glass alone still shows the rows' text through it; an opaque backing keeps the label readable.
            Group {
                if isSelected {
                    button.buttonStyle(.glassProminent)
                } else {
                    button.buttonStyle(.glass)
                }
            }
            .background(Color(.systemBackground), in: Capsule())
        } else if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        let button = Button {
            selection = []
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .frame(width: clearButtonSize, height: clearButtonSize)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel("Clear Filter")
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass).background(Color(.systemBackground), in: Circle())
        } else {
            button.buttonStyle(.bordered).tint(.secondary).background(.background, in: Circle())
        }
    }

    private func name(for account: Account) -> String {
        let name = settingsViewModel.name(for: account)
        return redactionEnabled && name.hasPrefix("@") ? "Redacted" : name
    }
}
