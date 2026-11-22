import SwiftUI
import UIKit

/// The home pages' titles as one row in the large title, "Chats  Notifications", replacing the page dots. The row
/// scrolls by a title's width while the pages scroll by a screen's, so a swipe moves both at once. It repeats
/// both ways (… Notifications, Chats, Notifications, Chats …), as the pages wrap around.
///
/// Each page puts a strip in its large title. `HomePagerController` sets `position` straight from the scroll
/// offset, like the dots before it, so a swipe never goes through SwiftUI state. Every strip draws the row
/// where it would be with the pager at rest, cut to its own page, so the two pages' strips meet as one row.
@MainActor
final class HomeTitleStripModel {
    static let titles = ["Chats", "Notifications"]

    /// The title at the leading edge: 0 is Chats and 1 Notifications, with Chats again at 2 and Notifications at
    /// -1 while a swipe wraps around. Between two titles mid-swipe.
    var position: CGFloat = 1 {
        didSet {
            guard position != oldValue else { return }
            strips.allObjects.forEach { $0.setNeedsLayout() }
        }
    }

    /// Both pages' root views, set by the pager.
    var pageViews: [UIView] = []
    /// A tapped title's index in the row, the same numbering as `position`.
    var select: ((Int) -> Void)?
    fileprivate let strips = NSHashTable<HomeTitleStripView>.weakObjects()
    /// Each page list's top content inset with the large title showing in full, kept here rather than in the strip:
    /// SwiftUI makes a new strip when a page comes back on screen, possibly with its title collapsed.
    fileprivate let restingInsets = NSMapTable<UIScrollView, NSNumber>.weakToStrongObjects()
    /// Each page's leading title as its own scroll would draw it: its centre on screen and how far it has shrunk
    /// towards the bar. Mid-swipe both pages' strips draw the row from these blended, so its halves meet.
    fileprivate var pageTitles: [Int: (center: CGFloat, collapse: CGFloat)] = [:]

    /// How much of a page (0 Chats, 1 Notifications) is on screen, 0 to 1, from `position`.
    fileprivate func visibility(ofPage page: Int) -> CGFloat {
        let indices = page == 0 ? [0, 2] : [-1, 1]
        return indices.map { max(0, 1 - abs(position - CGFloat($0))) }.max() ?? 0
    }

    /// Records a page's title and, when it changed mid-swipe, has the other page's strip follow it.
    fileprivate func report(page: Int, center: CGFloat, collapse: CGFloat) {
        let old = pageTitles[page]
        pageTitles[page] = (center, collapse)
        guard position.rounded() != position,
              old.map({ abs($0.center - center) > 0.01 || abs($0.collapse - collapse) > 0.001 }) ?? true else { return }
        strips.allObjects.filter { $0.pageIndex != page }.forEach { $0.setNeedsLayout() }
    }

    /// The index in the row of the title at a point in `view`, on whichever page's strip is on screen there.
    func titleIndex(at point: CGPoint, in view: UIView) -> Int? {
        for strip in strips.allObjects where strip.window != nil {
            if let index = strip.titleIndex(at: view.convert(point, to: strip)) {
                return index
            }
        }
        return nil
    }

    static func title(at index: Int) -> String {
        titles[((index % titles.count) + titles.count) % titles.count]
    }
}

extension View {
    /// The page's large title as the home title strip, on iOS 26 and later; the plain title before.
    @ViewBuilder
    func homeTitleStrip(model: HomeTitleStripModel, page: HomePage) -> some View {
        if #available(iOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .largeTitle) {
                    HomeTitleStrip(model: model, page: page)
                }
                // In place of the bar's own inline title, which came in blurred, sliding up from below, as the
                // strip's leading title arrived in its place, and in a lighter weight.
                ToolbarItem(placement: .principal) {
                    HomeInlineTitle(title: HomeTitleStripModel.title(at: page == .chats ? 0 : 1))
                }
            }
        } else {
            self
        }
    }
}

/// Accessibility is SwiftUI's: the UIKit labels didn't reach the accessibility tree. Taps are the pager's
/// (`HomeTitleStripModel.titleIndex(at:)`): nothing in the large title receives touches, UIKit or SwiftUI.
private struct HomeTitleStrip: View {
    let model: HomeTitleStripModel
    let page: HomePage

    var body: some View {
        let index = page == .chats ? 0 : 1
        HomeTitleStripRepresentable(model: model)
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                Text(HomeTitleStripModel.title(at: index))
                    .accessibilityAddTraits(.isHeader)
                Button(HomeTitleStripModel.title(at: index + 1)) {
                    model.select?(index + 1)
                }
            }
    }
}

private struct HomeTitleStripRepresentable: UIViewRepresentable {
    let model: HomeTitleStripModel

    func makeUIView(context _: Context) -> HomeTitleStripView {
        let view = HomeTitleStripView(model: model)
        model.strips.add(view)
        return view
    }

    func updateUIView(_: HomeTitleStripView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HomeTitleStripView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.font.lineHeight * 8, height: ceil(uiView.font.lineHeight))
    }
}

/// The page's title in the collapsed bar, the strip's leading title at its final size. Hidden until the strip's
/// title has shrunk into its place, then shown at once (`HomeTitleStripView` sets its alpha), so the swap can't be seen.
private struct HomeInlineTitle: UIViewRepresentable {
    let title: String

    func makeUIView(context _: Context) -> HomeInlineTitleView {
        let view = HomeInlineTitleView()
        view.alpha = 0
        return view
    }

    func updateUIView(_ view: HomeInlineTitleView, context _: Context) {
        view.text = title
    }
}

final class HomeInlineTitleView: UILabel {
    /// Read out only while shown: the strip is the page's heading until it collapses.
    override var alpha: CGFloat {
        didSet { accessibilityElementsHidden = alpha == 0 }
    }

    init() {
        super.init(frame: .zero)
        font = HomeTitleStripView.inlineFont
        textColor = .label
        accessibilityTraits.insert(.header)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.font = HomeTitleStripView.inlineFont
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class HomeTitleStripView: UIView {
    private static let spacing: CGFloat = 12
    private let model: HomeTitleStripModel
    /// One label per title that can be on screen: the row from one title before the leading one to two after.
    private let labels = (0 ..< 4).map { _ in UILabel() }
    private var labelIndices = [Int](repeating: 0, count: 4)
    /// Holds the labels, and shrinks and moves into the bar's inline title as the page scrolls up.
    private let row = UIView()
    private let pageMask = CALayer()
    /// The scroll view the navigation bar collapses with, and its offset observed to follow it.
    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?

    var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
    }

    /// The collapsed title: the large title's face at the inline title's size, so the shrunk strip matches it.
    static var inlineFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        let size = UIFont.preferredFont(forTextStyle: .headline).pointSize
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: size)
    }

    /// The bar's `HomeInlineTitle`, shown once the strip has collapsed into it.
    private weak var inlineTitle: HomeInlineTitleView?
    /// While the bar fades the large title back in: see `showInlineTitle(collapse:)`.
    private var fadeLink: CADisplayLink?
    private var lastCollapse: CGFloat = 0

    init(model: HomeTitleStripModel) {
        self.model = model
        super.init(frame: .zero)
        pageMask.backgroundColor = UIColor.black.cgColor
        layer.mask = pageMask
        isUserInteractionEnabled = false
        addSubview(row)
        labels.forEach(row.addSubview)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFollowingFade() }
        observeScrollView()
        setNeedsLayout()
    }

    /// The navigation bar whose inline title the strip collapses into.
    private var navigationBar: UINavigationBar? {
        sequence(first: next, next: { $0?.next }).lazy.compactMap { $0 as? UINavigationController }.first?.navigationBar
    }

    /// The large title sits in the list's scroll view and scrolls with it (observed 2026-11-22 on iOS 27), so the
    /// nearest scroll view above the strip is the one it collapses with.
    private func observeScrollView() {
        let found = sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        guard found !== scrollView else { return }
        scrollView = found
        offsetObservation = found?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView?.window == nil { observeScrollView() }
        let page = model.pageViews.first { isDescendant(of: $0) }
        // How far this strip's page has moved off the screen's leading edge: the row is drawn that far back,
        // so it stays where it is while the page slides.
        let pageShift = page.map { $0.convert(CGPoint.zero, to: nil).x } ?? 0

        let font = font
        let leading = Int(floor(model.position))
        let progress = model.position - CGFloat(leading)
        let widths = (leading - 1 ... leading + 2).map {
            ceil((HomeTitleStripModel.title(at: $0) as NSString).size(withAttributes: [.font: font]).width)
        }
        // Positions relative to the leading title, then moved along by the swipe's progress to the next one.
        var origins = [-(widths[0] + Self.spacing), 0]
        origins.append(widths[1] + Self.spacing)
        origins.append(origins[2] + widths[2] + Self.spacing)
        let scroll = progress * (widths[1] + Self.spacing)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.transform = .identity
        row.frame = bounds
        let collapse = layoutCollapse(
            leadingCenterX: origins[1] - scroll - pageShift + widths[1] / 2,
            restingLeadingCenterX: origins[1] + widths[1] / 2,
            font: font,
        )
        // The other titles are gone by halfway, so only the leading one reaches the bar.
        let othersAlpha = max(0, 1 - 2 * collapse)
        for (slot, label) in labels.enumerated() {
            let index = leading - 1 + slot
            labelIndices[slot] = index
            let closeness = max(0, 1 - abs(model.position - CGFloat(index)))
            label.font = font
            label.text = HomeTitleStripModel.title(at: index)
            label.textColor = UIColor.label.withAlphaComponent(0.35 + 0.65 * closeness)
            // Only the leading title and the next show at rest: the one before fades in as a swipe back brings it
            // in, and the one after next as a swipe forward makes it the next.
            let distance = CGFloat(index) - model.position
            let swipeAlpha = distance < 0 ? max(0, 1 + distance) : max(0, min(1, 2 - distance))
            label.alpha = swipeAlpha * (index == Int(model.position.rounded()) ? 1 : othersAlpha)
            label.frame = CGRect(x: origins[slot] - scroll - pageShift, y: 0, width: widths[slot], height: bounds.height)
        }
        // Cut to the page mid-swipe, so the other page's strip draws the rest of the row. Not at rest: measured while a
        // pushed screen was popping, with the page still sliding in, the cut stayed where it was and clipped the
        // leading title until the list next scrolled.
        let isSwiping = model.position.rounded() != model.position
        pageMask.frame = isSwiping ? page.map { $0.convert($0.bounds, to: self).insetBy(dx: 0, dy: -1000) } ?? bounds.insetBy(dx: -1000, dy: -1000)
            : bounds.insetBy(dx: -10000, dy: -1000)
        CATransaction.commit()
        if window != nil { showInlineTitle(collapse: collapse) }
    }

    /// Shrinks and moves the row so the leading title turns into the bar's inline title as the page scrolls up: it
    /// scales from the large title's size to the inline title's and slides to the bar's centre, arriving as the
    /// bar hides the large title and shows its own inline title in that same place. Returns the progress, 0 at
    /// rest to 1 collapsed.
    ///
    /// The large title sits in the list's scroll view, above its content. Scrolling up first shrinks the top
    /// content inset by the large title's height, with the offset following so the content stays put relative to
    /// it; once the inset bottoms out the bar hides the large title and shows its inline one (observed 2026-11-22
    /// on iOS 27). So the progress is how much of that inset is gone.
    ///
    /// Mid-swipe both pages' strips draw the row the same way: from the two pages' titles blended by how much of each
    /// is on screen, leaving out a page whose title has collapsed (the bar hides it). Each drawing its own, the halves
    /// met out of line when one list rested a little scrolled.
    private func layoutCollapse(leadingCenterX: CGFloat, restingLeadingCenterX: CGFloat, font: UIFont) -> CGFloat {
        // Off screen (scrolled far away, or another screen pushed) the inline title keeps what it last showed.
        guard let scrollView, let bar = navigationBar, window != nil else { return 0 }
        let inset = scrollView.adjustedContentInset.top
        let restingInset = max(model.restingInsets.object(forKey: scrollView).map { CGFloat($0.doubleValue) } ?? inset, inset)
        model.restingInsets.setObject(NSNumber(value: Double(restingInset)), forKey: scrollView)
        let span = largeTitleView?.bounds.height ?? bounds.height
        let progress = min(1, max(0, (restingInset - inset) / span))
        if inlineTitle?.window == nil { inlineTitle = Self.inlineTitle(in: bar) }

        // The middle of the bar's top row (44pt, under the status bar), where its inline title sits.
        let barFrame = bar.convert(bar.bounds, to: nil)
        let target = barFrame.minY + 22
        let center = convert(CGPoint(x: 0, y: bounds.midY), to: nil).y
        if let pageIndex { model.report(page: pageIndex, center: center, collapse: progress) }

        // The leading title's centre on screen and its progress, blended across the pages' visible titles.
        var weights: CGFloat = 0, drawnCenter: CGFloat = 0, drawnProgress: CGFloat = 0
        for (page, title) in model.pageTitles where title.collapse < 1 || page == pageIndex {
            let weight = model.visibility(ofPage: page)
            weights += weight
            drawnCenter += weight * (title.center + (target - title.center) * title.collapse)
            drawnProgress += weight * title.collapse
        }
        if weights > 0 {
            drawnCenter /= weights
            drawnProgress /= weights
        } else {
            drawnCenter = center + (target - center) * progress
            drawnProgress = progress
        }
        guard drawnProgress > 0 || abs(drawnCenter - center) > 0.01 else { return progress }

        let scale = 1 + (Self.inlineFont.pointSize / font.pointSize - 1) * drawnProgress
        // Towards the bar's centre by the distance at rest, which a swipe doesn't change.
        // The list's middle, the bar's too: unlike the screen's, it moves with a push or pop along with the strip.
        let x = (convert(CGPoint(x: scrollView.bounds.midX, y: 0), from: scrollView).x - restingLeadingCenterX) * drawnProgress
        let y = drawnCenter - center
        // Scaled about the leading title's centre.
        row.transform = CGAffineTransform(translationX: leadingCenterX - bounds.midX + x, y: y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: bounds.midX - leadingCenterX, y: 0)
        return progress
    }

    /// This strip's page: 0 Chats, 1 Notifications.
    fileprivate var pageIndex: Int? {
        model.pageViews.firstIndex { isDescendant(of: $0) }
    }

    /// The large title's own view: the scroll view's subview holding the strip.
    private var largeTitleView: UIView? {
        sequence(first: self as UIView, next: \.superview).first { $0.superview != nil && $0.superview === scrollView }
    }

    /// Shows the bar's inline title once the strip has collapsed into it, at once, so the swap can't be seen. On the
    /// way back it shows as much as the bar is still hiding the large title, which it fades back in a frame or more
    /// after the title starts to grow: hidden at once, the title blinked out; faded by progress, it showed twice.
    private func showInlineTitle(collapse: CGFloat) {
        lastCollapse = collapse
        guard let inlineTitle else { return stopFollowingFade() }
        if collapse >= 1 {
            inlineTitle.alpha = 1
            return stopFollowingFade()
        }
        guard inlineTitle.alpha > 0, let largeTitle = largeTitleView, window != nil else {
            inlineTitle.alpha = 0
            return stopFollowingFade()
        }
        let shown = largeTitle.alpha == 0 ? 0 : CGFloat(largeTitle.layer.presentation()?.opacity ?? Float(largeTitle.alpha))
        inlineTitle.alpha = shown >= 0.99 ? 0 : 1 - shown
        if inlineTitle.alpha > 0 {
            followFade()
        } else {
            stopFollowingFade()
        }
    }

    /// Follows the large title's fade frame by frame, which moves no layout.
    private func followFade() {
        guard fadeLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(fadeStep))
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    @objc private func fadeStep() {
        showInlineTitle(collapse: lastCollapse)
    }

    private func stopFollowingFade() {
        fadeLink?.invalidate()
        fadeLink = nil
    }

    private static func inlineTitle(in bar: UINavigationBar) -> HomeInlineTitleView? {
        var views: [UIView] = [bar]
        while let view = views.popLast() {
            if let title = view as? HomeInlineTitleView { return title }
            views.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The index in the row of the visible title at a point, with a little slack around each.
    func titleIndex(at point: CGPoint) -> Int? {
        labels.indices.first {
            labels[$0].alpha > 0.5 && labels[$0].convert(labels[$0].bounds, to: self).insetBy(dx: -Self.spacing / 2, dy: -8).contains(point)
        }
        .map { labelIndices[$0] }
    }
}
