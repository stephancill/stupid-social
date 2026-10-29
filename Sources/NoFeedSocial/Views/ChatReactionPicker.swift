import UIKit

/// The "More Reactions" sheet: a grid of common emoji; picking one toggles it on the message.
final class ChatReactionPickerViewController: UIViewController, UICollectionViewDelegate {
    private static let emojis = [
        "👍", "👎", "❤️", "🔥", "😂", "🤣", "😮", "😢", "😡", "🙏", "👏", "🎉",
        "🤔", "😍", "🥲", "😅", "😎", "🤯", "💯", "✅", "❌", "👀", "🚀", "🙌",
        "💪", "🤝", "🫡", "😴", "🤷", "🍕", "☕️", "🐛", "⚡️", "💀", "🥳", "😬",
    ]

    private let selected: Set<String>
    private let onSelect: (String) -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(selected: Set<String>, onSelect: @escaping (String) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 6), heightDimension: .fractionalWidth(1 / 6)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / 6)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 12, bottom: 24, trailing: 12)
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        let selected = selected
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, emoji in
            var content = UIListContentConfiguration.cell()
            content.text = emoji
            content.textProperties.font = .systemFont(ofSize: 30)
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.clear()
            background.cornerRadius = 12
            background.backgroundColor = selected.contains(emoji) ? UIColor.link.withAlphaComponent(0.18) : .clear
            cell.backgroundConfiguration = background
            cell.accessibilityLabel = emoji
            cell.accessibilityTraits = selected.contains(emoji) ? [.button, .selected] : .button
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, emoji in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: emoji)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(Self.emojis)
        dataSource.apply(snapshot)
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let emoji = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect(emoji)
        dismiss(animated: true)
    }
}
