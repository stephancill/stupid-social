import NoFeedSocialCore
import UIKit

/// The "More Reactions" sheet: the chat's custom emoji, a section per category, then a grid of common emoji;
/// picking one toggles it on the message.
final class ChatReactionPickerViewController: UIViewController, UICollectionViewDelegate {
    private static let emojis = [
        "👍", "👎", "❤️", "🔥", "😂", "🤣", "😮", "😢", "😡", "🙏", "👏", "🎉",
        "🤔", "😍", "🥲", "😅", "😎", "🤯", "💯", "✅", "❌", "👀", "🚀", "🙌",
        "💪", "🤝", "🫡", "😴", "🤷", "🍕", "☕️", "🐛", "⚡️", "💀", "🥳", "😬",
    ]

    private let selected: Set<String>
    private let customEmojis: [String: ChatCustomEmoji]
    /// Section titles, in order; the common emoji's section has none.
    private let sections: [(title: String?, items: [String])]
    private let onSelect: (String) -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(selected: Set<String>, customEmojis: [ChatCustomEmoji] = [], onSelect: @escaping (String) -> Void) {
        self.selected = selected
        self.customEmojis = Dictionary(customEmojis.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.onSelect = onSelect
        let byCategory = Dictionary(grouping: customEmojis) { $0.category ?? "" }
        // Uncategorized custom emoji first under the generic title, then categories alphabetically.
        let categories = byCategory.keys.sorted { lhs, rhs in
            lhs.isEmpty != rhs.isEmpty ? lhs.isEmpty : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let custom = categories.map { category in
            (
                title: category.isEmpty ? "Custom" : category,
                items: (byCategory[category] ?? []).map(\.key).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            )
        }
        sections = custom + [(title: custom.isEmpty ? nil : "Emoji", items: Self.emojis)]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let sections = sections
        let layout = UICollectionViewCompositionalLayout { index, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 6), heightDimension: .fractionalWidth(1 / 6)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / 6)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            let isLast = index == sections.count - 1
            section.contentInsets = NSDirectionalEdgeInsets(top: index == 0 && sections[index].title == nil ? 24 : 4, leading: 12, bottom: isLast ? 24 : 12, trailing: 12)
            if sections[index].title != nil {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top,
                )
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        let selected = selected
        let customEmojis = customEmojis
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.font = .systemFont(ofSize: 30)
            content.textProperties.alignment = .center
            if let custom = customEmojis[item] {
                // As text, so it centers like the emoji glyphs; at most two emoji wide.
                let font = UIFont.systemFont(ofSize: 30)
                let attachment = ChatCustomEmojiImages.shared.attachment(for: custom, font: font) { [weak self] in
                    guard let dataSource = self?.dataSource else { return }
                    var snapshot = dataSource.snapshot()
                    snapshot.reconfigureItems([item])
                    dataSource.apply(snapshot, animatingDifferences: false)
                }
                let scale = min(1, font.lineHeight * 2 / attachment.bounds.width)
                attachment.bounds = attachment.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
                content.attributedText = NSAttributedString(attachment: attachment)
                cell.accessibilityLabel = custom.label
            } else {
                content.text = item
                cell.accessibilityLabel = item
            }
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.clear()
            background.cornerRadius = 12
            background.backgroundColor = selected.contains(item) ? UIColor.link.withAlphaComponent(0.18) : .clear
            cell.backgroundConfiguration = background
            cell.accessibilityTraits = selected.contains(item) ? [.button, .selected] : .button
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { header, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = sections[indexPath.section].title
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        for (index, section) in sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.items, toSection: index)
        }
        dataSource.apply(snapshot)
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let emoji = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect(emoji)
        dismiss(animated: true)
    }
}
