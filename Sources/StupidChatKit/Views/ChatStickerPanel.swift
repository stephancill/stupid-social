import UIKit

/// The sticker panel, in the keyboard's place as in Telegram's apps: every set in one grid under its title, a tab per
/// set along the bottom that follows the scroll and jumps to its set, a row of emoji along the top that shows the
/// stickers for one, and a press-and-hold preview that plays the sticker with a Send button. A tap sends. Stickers in
/// the grid show their first frame, so dozens don't play at once. `preload` fetches the sets, their stickers, the
/// emoji row's results and the first stills when the chat opens, so the panel shows complete.
final class ChatStickerPanel: UIInputView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    var loadSets: () async throws -> [ChatStickerSet] = { [] }
    var loadStickers: (String) async throws -> [ChatSticker] = { _ in [] }
    var stickersForEmoji: (String) async throws -> [ChatSticker] = { _ in [] }
    var send: (ChatSticker) -> Void = { _ in }

    static let emoji = ["👍", "❤️", "😂", "😍", "😘", "🥰", "😭", "😮", "😡", "🥳", "🔥", "🙏", "👋", "🤔", "😴", "😎", "🎉", "👀", "💯", "😅"]

    private var sets: [ChatStickerSet] = []
    private var stickers: [String: [ChatSticker]] = [:]
    private var loadingSets: Set<String> = []
    private var selectedEmoji: String?
    private var emojiResults: [ChatSticker]?
    private var emojiTask: Task<Void, Never>?
    private var emojiCache: [String: [ChatSticker]] = [:]
    private var setsTask: Task<Bool, Never>?
    private var preloadTask: Task<Void, Never>?

    private let emojiBar = UIStackView()
    private let grid: UICollectionView
    private let tabs: UICollectionView
    private let statusLabel = UILabel()
    private var preview: UIView?

    init(height: CGFloat) {
        grid = UICollectionView(frame: .zero, collectionViewLayout: Self.gridLayout())
        let tabLayout = UICollectionViewFlowLayout()
        tabLayout.scrollDirection = .horizontal
        tabLayout.itemSize = CGSize(width: 40, height: 40)
        tabLayout.minimumLineSpacing = 4
        tabLayout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tabs = UICollectionView(frame: .zero, collectionViewLayout: tabLayout)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var height: CGFloat {
        get { frame.height }
        set { frame.size.height = newValue }
    }

    // MARK: Layout

    private static func columns(width: CGFloat) -> Int {
        max(4, Int(width / 76))
    }

    /// A grid cell's sticker side, in points, at a panel width.
    static func stickerSide(width: CGFloat) -> CGFloat {
        (width - 16) / CGFloat(columns(width: width)) - 6
    }

    private static func gridLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = columns(width: environment.container.effectiveContentSize.width)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalWidth(1 / CGFloat(columns))))
            item.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / CGFloat(columns))), repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(30)), elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func configureViews() {
        let emojiScroll = UIScrollView()
        emojiScroll.showsHorizontalScrollIndicator = false
        emojiBar.axis = .horizontal
        emojiBar.spacing = 2
        for emoji in Self.emoji {
            var configuration = UIButton.Configuration.plain()
            configuration.title = emoji
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            configuration.background.cornerRadius = 8
            let button = UIButton(configuration: configuration)
            button.titleLabel?.font = .systemFont(ofSize: 24)
            button.accessibilityLabel = "Stickers for \(emoji)"
            button.addAction(UIAction { [weak self] _ in self?.select(emoji: emoji) }, for: .primaryActionTriggered)
            emojiBar.addArrangedSubview(button)
        }
        emojiScroll.addSubview(emojiBar)
        emojiBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emojiBar.leadingAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.leadingAnchor, constant: 8),
            emojiBar.trailingAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            emojiBar.topAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.topAnchor),
            emojiBar.bottomAnchor.constraint(equalTo: emojiScroll.contentLayoutGuide.bottomAnchor),
            emojiBar.heightAnchor.constraint(equalTo: emojiScroll.frameLayoutGuide.heightAnchor),
        ])

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.prefetchDataSource = self
        grid.register(StickerCell.self, forCellWithReuseIdentifier: "sticker")
        grid.register(HeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        grid.addGestureRecognizer(hold)

        tabs.backgroundColor = .clear
        tabs.showsHorizontalScrollIndicator = false
        tabs.dataSource = self
        tabs.delegate = self
        tabs.register(TabCell.self, forCellWithReuseIdentifier: "tab")

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let separator = UIView()
        separator.backgroundColor = .separator
        for view in [emojiScroll, grid, separator, tabs, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            emojiScroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            emojiScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            emojiScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emojiScroll.heightAnchor.constraint(equalToConstant: 40),
            grid.topAnchor.constraint(equalTo: emojiScroll.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: grid.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            tabs.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 2),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 44),
            tabs.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    // MARK: Loading

    /// Shows the sets, loading them if `preload` hasn't.
    func load() {
        Task { await loadSetList() }
    }

    /// Everything the panel shows, before it shows: the sets, every set's stickers (for the grid and the tabs), the
    /// emoji row's results, and stills for the first screens, every tab and each emoji's first rows. Stills are
    /// cached on disk, so after the first time this mostly checks they're there.
    func preload(width: CGFloat, scale: CGFloat) {
        guard preloadTask == nil else { return }
        let side = (Self.stickerSide(width: width) * scale).rounded()
        preloadTask = Task {
            guard await loadSetList() else {
                preloadTask = nil
                return
            }
            await forEach(Array(sets.indices), concurrently: 3) { await self.loadSet(at: $0) }
            let ordered = sets.flatMap { stickers[$0.id] ?? [] }
            await prepareStills(ordered.prefix(60), side: side, warm: true)
            let covers = sets.compactMap { $0.cover ?? stickers[$0.id]?.first }
            await prepareStills(covers, side: side, warm: true)
            await prepareStills(ordered.prefix(160).dropFirst(60), side: side, warm: false)
            for emoji in Self.emoji {
                guard let results = try? await stickersForEmoji(emoji) else { continue }
                emojiCache[emoji] = results
                await prepareStills(results.prefix(15), side: side, warm: false)
            }
        }
    }

    private func prepareStills(_ stickers: some Sequence<ChatSticker>, side: CGFloat, warm: Bool) async {
        await forEach(Array(stickers), concurrently: 4) { sticker in
            await ChatStickerFiles.shared.prepareStill(for: sticker, side: side, warm: warm)
        }
    }

    /// Runs `body` over `items`, at most `limit` at a time.
    private func forEach<Item: Sendable>(_ items: [Item], concurrently limit: Int, _ body: @escaping @MainActor (Item) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                if index >= limit {
                    await group.next()
                }
                group.addTask { await body(item) }
            }
        }
    }

    /// Loads the sets once; a failure lets the next call try again. Returns whether they're loaded.
    @discardableResult
    private func loadSetList() async -> Bool {
        if let setsTask { return await setsTask.value }
        let task = Task<Bool, Never> {
            do {
                let sets = try await loadSets()
                self.sets = sets
                for set in sets {
                    if let loaded = set.stickers {
                        stickers[set.id] = loaded
                    }
                }
                statusLabel.text = sets.isEmpty ? "Stickers you add in Telegram show here." : nil
                grid.reloadData()
                tabs.reloadData()
                selectTab(0)
                return true
            } catch {
                statusLabel.text = "Couldn't load stickers. \(error.localizedDescription)"
                return false
            }
        }
        setsTask = task
        let loaded = await task.value
        if !loaded {
            setsTask = nil
        }
        return loaded
    }

    private func loadSet(at section: Int) async {
        guard section < sets.count else { return }
        let id = sets[section].id
        guard stickers[id] == nil, !loadingSets.contains(id) else { return }
        loadingSets.insert(id)
        defer { loadingSets.remove(id) }
        guard let loaded = try? await loadStickers(id) else { return }
        stickers[id] = loaded
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        if selectedEmoji == nil {
            UIView.performWithoutAnimation {
                grid.reloadSections([index])
            }
        }
        // A set without a thumbnail of its own takes its first sticker's. Reloading a tab drops its selection.
        guard sets[index].cover == nil else { return }
        let selected = tabs.indexPathsForSelectedItems?.first
        UIView.performWithoutAnimation {
            tabs.reloadItems(at: [IndexPath(item: index, section: 0)])
        }
        if let selected {
            tabs.selectItem(at: selected, animated: false, scrollPosition: [])
        }
    }

    /// The emoji's stickers in place of the sets; the same emoji again goes back to the sets.
    private func select(emoji: String) {
        emojiTask?.cancel()
        selectedEmoji = selectedEmoji == emoji ? nil : emoji
        emojiResults = nil
        for case let button as UIButton in emojiBar.arrangedSubviews {
            button.configuration?.background.backgroundColor = button.configuration?.title == selectedEmoji ? .secondarySystemFill : .clear
        }
        statusLabel.text = nil
        if let selectedEmoji, let cached = emojiCache[selectedEmoji] {
            emojiResults = cached
            statusLabel.text = cached.isEmpty ? "No stickers for \(selectedEmoji)" : nil
        }
        grid.reloadData()
        grid.setContentOffset(.zero, animated: false)
        guard let selectedEmoji, emojiResults == nil else { return }
        emojiTask = Task {
            let results = await (try? stickersForEmoji(selectedEmoji)) ?? []
            guard !Task.isCancelled, self.selectedEmoji == selectedEmoji else { return }
            emojiCache[selectedEmoji] = results
            emojiResults = results
            statusLabel.text = results.isEmpty ? "No stickers for \(selectedEmoji)" : nil
            grid.reloadData()
        }
    }

    /// After sending, the sticker leads Recent, as Telegram keeps it.
    func didSend(_ sticker: ChatSticker) {
        guard let index = sets.firstIndex(where: { $0.id == "recent" }) else { return }
        var recent = stickers["recent"] ?? []
        recent.removeAll { $0.id == sticker.id }
        recent.insert(sticker, at: 0)
        stickers["recent"] = recent
        let set = sets[index]
        sets[index] = ChatStickerSet(id: set.id, title: set.title, cover: set.cover, count: recent.count, stickers: recent)
        if selectedEmoji == nil {
            UIView.performWithoutAnimation {
                grid.reloadSections([index])
            }
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === tabs ? 1 : selectedEmoji != nil ? 1 : sets.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if collectionView === tabs { return sets.count }
        if selectedEmoji != nil { return emojiResults?.count ?? 0 }
        return stickers[sets[section].id]?.count ?? sets[section].count
    }

    private func sticker(at indexPath: IndexPath) -> ChatSticker? {
        if selectedEmoji != nil {
            return emojiResults.flatMap { indexPath.item < $0.count ? $0[indexPath.item] : nil }
        }
        guard indexPath.section < sets.count, let loaded = stickers[sets[indexPath.section].id], indexPath.item < loaded.count else { return nil }
        return loaded[indexPath.item]
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === tabs {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tab", for: indexPath) as! TabCell
            let set = sets[indexPath.item]
            cell.configure(set: set, cover: set.cover ?? stickers[set.id]?.first)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "sticker", for: indexPath) as! StickerCell
        cell.configure(sticker: sticker(at: indexPath))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! HeaderView
        header.label.text = (selectedEmoji ?? (indexPath.section < sets.count ? sets[indexPath.section].title : "")).uppercased()
        return header
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay _: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard collectionView === grid, selectedEmoji == nil else { return }
        // This set and the next, should the preload not have reached them.
        Task {
            await loadSet(at: indexPath.section)
            await loadSet(at: indexPath.section + 1)
        }
    }

    /// Stills for the rows about to scroll in, past what the preload drew.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard collectionView === grid else { return }
        let side = (Self.stickerSide(width: bounds.width) * (window?.screen.scale ?? traitCollection.displayScale)).rounded()
        let upcoming = indexPaths.compactMap(sticker(at:))
        Task { await prepareStills(upcoming, side: side, warm: true) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === tabs {
            if selectedEmoji != nil, let emoji = selectedEmoji {
                select(emoji: emoji)
            }
            scrollGrid(toSection: indexPath.item)
            return
        }
        guard let sticker = sticker(at: indexPath) else { return }
        send(sticker)
    }

    // MARK: Tabs follow the grid

    private var tabsFollowScroll = true

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === grid, tabsFollowScroll, selectedEmoji == nil, !sets.isEmpty else { return }
        let top = grid.contentOffset.y + grid.adjustedContentInset.top + 31
        let section = (0 ..< sets.count).last { section in
            (grid.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))?.frame.minY ?? .infinity) <= top
        } ?? 0
        selectTab(section)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === grid {
            tabsFollowScroll = true
        }
    }

    private func selectTab(_ index: Int) {
        guard index < sets.count else { return }
        let indexPath = IndexPath(item: index, section: 0)
        guard tabs.indexPathsForSelectedItems?.first != indexPath else { return }
        tabs.selectItem(at: indexPath, animated: true, scrollPosition: .centeredHorizontally)
    }

    private func scrollGrid(toSection section: Int) {
        grid.layoutIfNeeded()
        guard let header = grid.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) else { return }
        let maxOffset = max(grid.contentSize.height - grid.bounds.height + grid.adjustedContentInset.bottom, -grid.adjustedContentInset.top)
        tabsFollowScroll = false
        selectTab(section)
        grid.setContentOffset(CGPoint(x: 0, y: min(header.frame.minY - grid.adjustedContentInset.top, maxOffset)), animated: true)
        Task { await loadSet(at: section) }
    }

    // MARK: Preview

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let indexPath = grid.indexPathForItem(at: gesture.location(in: grid)), let sticker = sticker(at: indexPath) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showPreview(sticker)
    }

    /// The sticker large and playing over the panel, with Send; a tap elsewhere closes it.
    private func showPreview(_ sticker: ChatSticker) {
        preview?.removeFromSuperview()
        let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closePreview)))
        let side = min(220, bounds.height - 110)
        let stickerView = ChatStickerView(sticker: sticker)
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Send"
        configuration.cornerStyle = .capsule
        let sendButton = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.closePreview()
            self?.send(sticker)
        })
        let stack = UIStackView(arrangedSubviews: [stickerView, sendButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stickerView.widthAnchor.constraint(equalToConstant: side),
            stickerView.heightAnchor.constraint(equalToConstant: side),
            stack.centerXAnchor.constraint(equalTo: overlay.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.contentView.centerYAnchor),
        ])
        addSubview(overlay)
        preview = overlay
        overlay.alpha = 0
        UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
    }

    @objc private func closePreview() {
        guard let preview else { return }
        self.preview = nil
        UIView.animate(withDuration: 0.15, animations: { preview.alpha = 0 }, completion: { _ in preview.removeFromSuperview() })
    }

    // MARK: Cells

    private final class StickerCell: UICollectionViewCell {
        private var stickerView: ChatStickerView?

        func configure(sticker: ChatSticker?) {
            guard stickerView?.sticker != sticker else { return }
            stickerView?.removeFromSuperview()
            stickerView = nil
            accessibilityLabel = nil
            isAccessibilityElement = sticker != nil
            guard let sticker else { return }
            let view = ChatStickerView(sticker: sticker, animates: false)
            contentView.addSubview(view)
            view.pinToEdges(of: contentView)
            stickerView = view
            accessibilityLabel = sticker.label
            accessibilityTraits = .button
        }

        override var isHighlighted: Bool {
            didSet { contentView.alpha = isHighlighted ? 0.5 : 1 }
        }
    }

    private final class TabCell: UICollectionViewCell {
        private var content: UIView?

        func configure(set: ChatStickerSet, cover: ChatSticker?) {
            content?.removeFromSuperview()
            accessibilityLabel = set.title
            isAccessibilityElement = true
            accessibilityTraits = .button
            selectedBackgroundView = {
                let view = UIView()
                view.backgroundColor = .secondarySystemFill
                view.layer.cornerRadius = 8
                return view
            }()
            let view: UIView
            switch set.id {
            case "recent", "favorites":
                let image = UIImageView(image: UIImage(systemName: set.id == "recent" ? "clock" : "star"))
                image.tintColor = .secondaryLabel
                image.contentMode = .center
                image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
                view = image
            default:
                if let cover {
                    let sticker = ChatStickerView(sticker: cover, animates: false)
                    sticker.isAccessibilityElement = false
                    view = sticker
                } else {
                    let label = UILabel()
                    label.text = String(set.title.prefix(1)).uppercased()
                    label.font = .preferredFont(forTextStyle: .headline)
                    label.textColor = .secondaryLabel
                    label.textAlignment = .center
                    view = label
                }
            }
            contentView.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: 30),
                view.heightAnchor.constraint(equalToConstant: 30),
            ])
            content = view
        }
    }

    private final class HeaderView: UICollectionReusableView {
        let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
