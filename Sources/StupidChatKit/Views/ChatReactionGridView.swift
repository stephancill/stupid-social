import UIKit

/// The grid a message's reaction row expands into, as in Telegram: a search field over the chat's custom emoji and
/// every emoji by category, the user's reactions marked. `ChatReactionGrid` decides the sections.
final class ChatReactionGridView: UIView, UICollectionViewDelegate, UISearchTextFieldDelegate {
    private let customEmojis: [String: ChatCustomEmoji]
    private let choices: [String]?
    private let selected: Set<String>
    private let onSelect: (String) -> Void
    private let searchField = UISearchTextField()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, ChatReactionGrid.Item>!
    private var sections: [ChatReactionGrid.Section] = []

    private static let columns = 8

    init(customEmojis: [String: ChatCustomEmoji], choices: [String]?, selected: Set<String>, onSelect: @escaping (String) -> Void) {
        self.customEmojis = customEmojis
        self.choices = choices
        self.selected = selected
        self.onSelect = onSelect
        super.init(frame: .zero)
        configure()
        apply(query: "")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        searchField.placeholder = "Search Emoji"
        searchField.returnKeyType = .done
        searchField.delegate = self
        searchField.addAction(UIAction { [weak self] _ in self?.apply(query: self?.searchField.text ?? "") }, for: .editingChanged)

        let layout = UICollectionViewCompositionalLayout { [weak self] index, _ in
            let fraction = 1 / CGFloat(Self.columns)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction), heightDimension: .fractionalWidth(fraction)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            let isLast = index == (self?.sections.count ?? 1) - 1
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: isLast ? 8 : 4, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(28)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top,
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag

        let selected = selected
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, ChatReactionGrid.Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.directionalLayoutMargins = .zero
            content.textProperties.alignment = .center
            switch item {
            case let .custom(emoji):
                let font = UIFont.systemFont(ofSize: 28)
                let attachment = ChatCustomEmojiImages.shared.attachment(for: emoji, font: font) { [weak self] in
                    self?.reconfigure(item)
                }
                // At most one emoji wide, so wide ones fit the cell.
                let scale = min(1, font.lineHeight / attachment.bounds.width)
                attachment.bounds = attachment.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
                content.attributedText = NSAttributedString(attachment: attachment)
                cell.accessibilityLabel = emoji.label
            case let .emoji(emoji):
                content.text = emoji
                content.textProperties.font = .systemFont(ofSize: 28)
                cell.accessibilityLabel = emoji
            }
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.clear()
            background.cornerRadius = 10
            background.backgroundColor = selected.contains(item.key) ? .tertiarySystemFill : .clear
            cell.backgroundConfiguration = background
            cell.accessibilityTraits = selected.contains(item.key) ? [.button, .selected] : .button
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.sections[safe: indexPath.section]?.title
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = .secondaryLabel
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8)
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        for subview in [searchField, collectionView!] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            // The size of the emoji keyboard's search field: 40 pt tall, 9 pt in from each side.
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            collectionView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(query: String) {
        sections = ChatReactionGrid.sections(customEmojis: customEmojis, choices: choices, query: query)
        var snapshot = NSDiffableDataSourceSnapshot<String, ChatReactionGrid.Item>()
        // A snapshot takes each item once, and a choice can also be among the search results.
        var seen = Set<ChatReactionGrid.Item>()
        for (index, section) in sections.enumerated() {
            // By title too, so a header whose title changed is drawn again.
            let id = "\(index)|\(section.title)"
            snapshot.appendSections([id])
            snapshot.appendItems(section.items.filter { seen.insert($0).inserted }, toSection: id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.setContentOffset(.zero, animated: false)
    }

    private func reconfigure(_ item: ChatReactionGrid.Item) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        searchField.resignFirstResponder()
        onSelect(item.key)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
