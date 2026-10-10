import ExpoModulesCore
import UIKit

final class StoryCaptionToolbarView: ExpoView {
    let onAction = EventDispatcher()
    private let toolbar = UIToolbar()
    private weak var editor: UITextView?
    private var editingObserver: NSObjectProtocol?
    var backgroundIndex = 0 {
        didSet { refresh() }
    }

    var colorIndex = 0 {
        didSet { refresh() }
    }

    var fontIndex = 0 {
        didSet { refresh() }
    }

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        toolbar.autoresizingMask = [.flexibleWidth]
        editingObserver = NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let textView = notification.object as? UITextView, let window, textView.window === window else { return }
            attach(to: textView)
        }
        refresh()
    }

    deinit {
        if let editingObserver { NotificationCenter.default.removeObserver(editingObserver) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else {
            if editor?.inputAccessoryView === toolbar {
                editor?.inputAccessoryView = nil
                editor?.reloadInputViews()
            }
            editor = nil
            return
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let textView = activeTextView(in: window) else { return }
            attach(to: textView)
        }
    }

    private func activeTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isFirstResponder { return textView }
        return view.subviews.lazy.compactMap { self.activeTextView(in: $0) }.first
    }

    private func attach(to textView: UITextView) {
        guard textView.inputAccessoryView !== toolbar else { return }
        editor = textView
        toolbar.frame = CGRect(x: 0, y: 0, width: window?.bounds.width ?? 0, height: 48)
        textView.inputAccessoryView = toolbar
        textView.reloadInputViews()
    }

    private func swatch(_ color: UIColor) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        view.backgroundColor = color == .clear ? UIColor.systemBackground.withAlphaComponent(0.5) : color
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor.label.withAlphaComponent(0.45).cgColor
        return view
    }

    private func item(label: String, action: String, content: UIView) -> UIBarButtonItem {
        let button = UIButton(type: .system)
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in self?.onAction(["action": action]) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 36),
            content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            content.widthAnchor.constraint(equalToConstant: content.bounds.width),
            content.heightAnchor.constraint(equalToConstant: content.bounds.height),
        ])
        return UIBarButtonItem(customView: button)
    }

    private func refresh() {
        let backgrounds: [UIColor] = [.black.withAlphaComponent(0.35), .white.withAlphaComponent(0.55), .clear, .systemRed.withAlphaComponent(0.75), .systemBlue.withAlphaComponent(0.75)]
        let colors: [UIColor] = [.white, .black, .systemYellow, .systemPink, .systemBlue]
        let designs: [UIFontDescriptor.SystemDesign] = [.default, .rounded, .serif, .monospaced]
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        label.text = "A"
        label.textAlignment = .center
        label.textColor = .label
        let base = UIFont.systemFont(ofSize: 24, weight: .bold)
        label.font = UIFont(descriptor: base.fontDescriptor.withDesign(designs[max(0, min(fontIndex, 3))]) ?? base.fontDescriptor, size: 24)
        let done = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in self?.onAction(["action": "done"]) })
        done.accessibilityLabel = "Done editing text"
        toolbar.items = [
            item(label: "Change text background", action: "background", content: swatch(backgrounds[max(0, min(backgroundIndex, 4))])),
            UIBarButtonItem(systemItem: .fixedSpace),
            item(label: "Change font", action: "font", content: label),
            UIBarButtonItem(systemItem: .fixedSpace),
            item(label: "Change text color", action: "color", content: swatch(colors[max(0, min(colorIndex, 4))])),
            UIBarButtonItem(systemItem: .flexibleSpace), done,
        ]
        toolbar.items?[1].width = 10
        toolbar.items?[3].width = 10
    }
}

public final class StoryCaptionToolbarModule: Module {
    public func definition() -> ModuleDefinition {
        Name("StoryCaptionToolbar")
        View(StoryCaptionToolbarView.self) {
            Events("onAction")
            Prop("backgroundIndex") { (view: StoryCaptionToolbarView, value: Int) in view.backgroundIndex = value }
            Prop("colorIndex") { (view: StoryCaptionToolbarView, value: Int) in view.colorIndex = value }
            Prop("fontIndex") { (view: StoryCaptionToolbarView, value: Int) in view.fontIndex = value }
        }
    }
}
