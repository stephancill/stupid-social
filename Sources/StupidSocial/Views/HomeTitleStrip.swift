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

    static func title(at index: Int) -> String {
        titles[((index % titles.count) + titles.count) % titles.count]
    }
}

extension View {
    /// The page's large title as the home title strip, on iOS 26 and later; the plain title before.
    @ViewBuilder
    func homeTitleStrip(_ model: HomeTitleStripModel) -> some View {
        if #available(iOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .largeTitle) {
                    HomeTitleStrip(model: model)
                }
            }
        } else {
            self
        }
    }
}

private struct HomeTitleStrip: UIViewRepresentable {
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

final class HomeTitleStripView: UIView {
    private static let spacing: CGFloat = 12
    private let model: HomeTitleStripModel
    /// One label per title that can be on screen: the row from one title before the leading one to two after.
    private let labels = (0 ..< 4).map { _ in UILabel() }
    private var labelIndices = [Int](repeating: 0, count: 4)
    private let pageMask = CALayer()

    var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
    }

    init(model: HomeTitleStripModel) {
        self.model = model
        super.init(frame: .zero)
        pageMask.backgroundColor = UIColor.black.cgColor
        layer.mask = pageMask
        for label in labels {
            label.isAccessibilityElement = true
            addSubview(label)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
        let current = Int(model.position.rounded())
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
            label.alpha = distance < 0 ? max(0, 1 + distance) : max(0, min(1, 2 - distance))
            label.frame = CGRect(x: origins[slot] - scroll - pageShift, y: 0, width: widths[slot], height: bounds.height)
            label.accessibilityTraits = index == current ? [.header, .selected] : .button
            label.isAccessibilityElement = index == current || index == current + 1
        }
        // Cut to the page, so the other page's strip draws the rest of the row.
        pageMask.frame = page.map { $0.convert($0.bounds, to: self).insetBy(dx: 0, dy: -100) } ?? bounds.insetBy(dx: -1000, dy: -100)
        CATransaction.commit()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let slot = labels.firstIndex(where: { $0.frame.insetBy(dx: -Self.spacing / 2, dy: -8).contains(point) }) else { return }
        model.select?(labelIndices[slot])
    }
}
