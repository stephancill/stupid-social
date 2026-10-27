import SwiftUI
import UIKit

enum HomePage: String, Hashable {
    case chats
    case social
}

/// Chats to the left of the feed, swiped between like Instagram's camera and inbox. A `UIPageViewController`
/// hosts each side as a child view controller; SwiftUI's paging `TabView` and `ScrollView` dropped the
/// navigation bars' layout margins, leaving large titles against the screen edge.
struct HomePager<Chats: View, Social: View>: UIViewControllerRepresentable {
    @Binding var page: HomePage
    /// Off while the visible side has a screen pushed, so back swipes and swipe-to-reply aren't taken over.
    /// The page dots hide with it, so they never cover a chat's composer.
    let isPagingEnabled: Bool
    let chats: Chats
    let social: Social

    func makeCoordinator() -> Coordinator {
        Coordinator(page: $page, chats: UIHostingController(rootView: chats), social: UIHostingController(rootView: social))
    }

    func makeUIViewController(context: Context) -> HomePagerController {
        let controller = HomePagerController()
        controller.pageController.dataSource = context.coordinator
        controller.pageController.delegate = context.coordinator
        controller.pageController.setViewControllers([context.coordinator.controller(for: page)], direction: .forward, animated: false)
        controller.leftPage = context.coordinator.chats
        return controller
    }

    func updateUIViewController(_ controller: HomePagerController, context: Context) {
        let coordinator = context.coordinator
        coordinator.page = $page
        coordinator.chats.rootView = chats
        coordinator.social.rootView = social
        controller.setPagingEnabled(isPagingEnabled)
        // A page set from outside, such as by a tapped notification, and not by a swipe.
        let target = coordinator.controller(for: page)
        if controller.pageController.viewControllers?.first !== target {
            controller.show(target)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var page: Binding<HomePage>
        let chats: UIHostingController<Chats>
        let social: UIHostingController<Social>

        init(page: Binding<HomePage>, chats: UIHostingController<Chats>, social: UIHostingController<Social>) {
            self.page = page
            self.chats = chats
            self.social = social
        }

        func controller(for page: HomePage) -> UIViewController {
            page == .chats ? chats : social
        }

        func pageViewController(_: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            viewController === social ? chats : nil
        }

        func pageViewController(_: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            viewController === chats ? social : nil
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating _: Bool, previousViewControllers _: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = controller.viewControllers?.first else { return }
            page.wrappedValue = current === chats ? .chats : .social
        }
    }
}

/// The page controller with the page dots over it. The dots are updated straight from the scroll offset:
/// routing every offset change through SwiftUI state re-rendered both pages mid-swipe and cancelled the pan.
final class HomePagerController: UIViewController {
    let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    /// The page at progress 0; the other is at 1.
    weak var leftPage: UIViewController?
    private let dots = HomePageDotsView()
    private var offsetObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        observeScrolling()

        dots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    /// Shows a page without a swipe.
    func show(_ page: UIViewController) {
        let isLeft = page === leftPage
        pageController.setViewControllers([page], direction: isLeft ? .reverse : .forward, animated: false)
        dots.progress = isLeft ? 0 : 1
    }

    func setPagingEnabled(_ enabled: Bool) {
        scrollView?.isScrollEnabled = enabled
        dots.isHidden = !enabled
    }

    /// The scroll view rests one page in, with the current page in the middle, and moves a page either way
    /// during a swipe. It stays the page controller's own delegate, so the offset is observed instead.
    private func observeScrolling() {
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self, scrollView.bounds.width > 0 else { return }
                let current: CGFloat = self.pageController.viewControllers?.first === self.leftPage ? 0 : 1
                let shift = (scrollView.contentOffset.x - scrollView.bounds.width) / scrollView.bounds.width
                self.dots.progress = min(1, max(0, current + shift))
            }
        }
    }

    private var scrollView: UIScrollView? {
        pageController.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }
}

/// Two dots like the story rows' indicator: each grows and darkens with how close the scroll position is to
/// its page, so they move continuously with a swipe.
final class HomePageDotsView: UIView {
    private static let minimumSize: CGFloat = 5
    private static let growth: CGFloat = 2
    private static let spacing: CGFloat = 5
    /// Padding inside the pill that keeps the dots legible over content.
    private static let inset = UIEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
    private let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let dotViews = [UIView(), UIView()]

    /// 0 on Chats, 1 on Social.
    var progress: CGFloat = 1 {
        didSet {
            guard progress != oldValue else { return }
            setNeedsLayout()
            accessibilityLabel = progress < 0.5 ? "Chats, page 1 of 2" : "Social, page 2 of 2"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pill.clipsToBounds = true
        addSubview(pill)
        dotViews.forEach(addSubview)
        isAccessibilityElement = true
        accessibilityLabel = "Social, page 2 of 2"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let largest = Self.minimumSize + Self.growth
        return CGSize(
            width: largest * 2 + Self.spacing + Self.inset.left + Self.inset.right,
            height: largest + Self.inset.top + Self.inset.bottom,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = bounds
        pill.layer.cornerRadius = bounds.height / 2
        let slot = Self.minimumSize + Self.growth
        for (index, dot) in dotViews.enumerated() {
            let intensity = max(0, 1 - abs(progress - CGFloat(index)))
            let size = Self.minimumSize + Self.growth * intensity
            let centerX = Self.inset.left + slot / 2 + CGFloat(index) * (slot + Self.spacing)
            dot.frame = CGRect(x: centerX - size / 2, y: (bounds.height - size) / 2, width: size, height: size)
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.25 + 0.75 * intensity)
        }
    }
}
