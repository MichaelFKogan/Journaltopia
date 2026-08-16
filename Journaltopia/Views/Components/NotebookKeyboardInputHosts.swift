import SwiftUI
import UIKit

enum NotebookKeyboardFormattingMode: String, CaseIterable, Identifiable, Equatable {
    case font
    case textType
    case color
    case textSize

    var id: String { rawValue }
}

enum NotebookEditorInputMode: Equatable {
    case systemKeyboard
    case formattingPanel(NotebookKeyboardFormattingMode)

    var panelMode: NotebookKeyboardFormattingMode? {
        switch self {
        case .systemKeyboard:
            nil
        case .formattingPanel(let mode):
            mode
        }
    }

    var showsFormattingPanel: Bool {
        panelMode != nil
    }
}

/// Hosts SwiftUI chrome inside keyboard-owned views without attaching a child view controller.
final class NotebookAnyViewInputHost: UIView {
    static let toolbarHeight: CGFloat = 48

    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
    private var heightConstraint: NSLayoutConstraint?
    private let fixedHeight: CGFloat?

    init(fixedHeight: CGFloat? = nil) {
        self.fixedHeight = fixedHeight
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let width = resolvedWidth
        if let fixedHeight {
            return CGSize(width: width, height: fixedHeight)
        }

        return CGSize(width: width, height: bounds.height > 0 ? bounds.height : UIView.noIntrinsicMetric)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachHostedViewIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostingController.view.frame = bounds
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width > 0 ? size.width : resolvedWidth
        if let fixedHeight {
            return CGSize(width: width, height: fixedHeight)
        }

        return CGSize(width: width, height: bounds.height > 0 ? bounds.height : 0)
    }

    func setRootView(_ view: AnyView) {
        hostingController.rootView = view
        hostingController.view.setNeedsLayout()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var resolvedWidth: CGFloat {
        bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
    }

    private func configure() {
        backgroundColor = UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
        isUserInteractionEnabled = true
        insetsLayoutMarginsFromSafeArea = false

        hostingController.view.backgroundColor = .clear
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }

        if let fixedHeight {
            frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: fixedHeight)
            let constraint = heightAnchor.constraint(equalToConstant: fixedHeight)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    private func attachHostedViewIfNeeded() {
        guard hostingController.view.superview !== self else {
            return
        }

        addSubview(hostingController.view)
    }
}

/// Custom keyboard replacement for formatting panels. Sits below the toolbar accessory.
/// UIKit assigns the height via `_UIKBAutolayoutHeightConstraint` to match the system keyboard.
final class NotebookInputPanelView: UIInputView {
    private let contentHost: NotebookAnyViewInputHost

    init(contentHost: NotebookAnyViewInputHost) {
        self.contentHost = contentHost
        let width = UIScreen.main.bounds.width
        super.init(
            frame: CGRect(x: 0, y: 0, width: width, height: 260),
            inputViewStyle: .keyboard
        )
        allowsSelfSizing = false
        backgroundColor = UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
        insetsLayoutMarginsFromSafeArea = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
