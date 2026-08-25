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
    private let leadingKeyboardCornerFill = KeyboardCornerWedgeView(side: .leading)
    private let trailingKeyboardCornerFill = KeyboardCornerWedgeView(side: .trailing)

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
        if window != nil {
            KeyboardCornerRadiusRemover.removeKeyboardCornerRadius()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostingController.view.frame = bounds
        KeyboardCornerRadiusRemover.flattenCorners(of: self)
        layoutKeyboardCornerFills()
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
        backgroundColor = KeyboardCornerRadiusRemover.toolbarFillColor
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The iOS 26 keyboard rounds its own top corners. The toolbar has to overflow those
        // wedges or the wallpaper shows through the square-to-round join.
        clipsToBounds = false
        isUserInteractionEnabled = true
        insetsLayoutMarginsFromSafeArea = false
        KeyboardCornerRadiusRemover.flattenCorners(of: self)

        hostingController.view.backgroundColor = .clear
        hostingController.view.clipsToBounds = true
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }

        leadingKeyboardCornerFill.isUserInteractionEnabled = false
        trailingKeyboardCornerFill.isUserInteractionEnabled = false
        addSubview(leadingKeyboardCornerFill)
        addSubview(trailingKeyboardCornerFill)

        if let fixedHeight {
            frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: fixedHeight)
            let constraint = heightAnchor.constraint(equalToConstant: fixedHeight)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    private func layoutKeyboardCornerFills() {
        let radius = KeyboardCornerRadiusRemover.resolvedKeyboardCornerRadius()
        let shouldShowFills = radius > 0 && bounds.width > 0 && bounds.height > 0
        leadingKeyboardCornerFill.isHidden = !shouldShowFills
        trailingKeyboardCornerFill.isHidden = !shouldShowFills
        guard shouldShowFills else {
            return
        }

        leadingKeyboardCornerFill.radius = radius
        trailingKeyboardCornerFill.radius = radius
        leadingKeyboardCornerFill.frame = CGRect(x: 0, y: bounds.height, width: radius, height: radius)
        trailingKeyboardCornerFill.frame = CGRect(
            x: bounds.width - radius,
            y: bounds.height,
            width: radius,
            height: radius
        )
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
        backgroundColor = KeyboardCornerRadiusRemover.toolbarFillColor
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = false
        insetsLayoutMarginsFromSafeArea = false
        KeyboardCornerRadiusRemover.flattenCorners(of: self)

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

    override func layoutSubviews() {
        super.layoutSubviews()
        KeyboardCornerRadiusRemover.flattenCorners(of: self)
    }
}

/// iOS 26 rounds the system keyboard independently of any `inputAccessoryView`. Walking the
/// keyboard window and zeroing `layer.cornerRadius` is not enough — the radius now lives on
/// `cornerConfiguration`. The toolbar also paints the leftover corner wedges so a square menu
/// can sit flush even if the system reapplies the radius mid-animation.
enum KeyboardCornerRadiusRemover {
    static let toolbarFillColor = UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)

    private static let fallbackKeyboardCornerRadius: CGFloat = 28
    private static let retryIntervals: [TimeInterval] = [0, 0.05, 0.16, 0.32, 0.55]
    private static var measuredKeyboardCornerRadius: CGFloat = 0

    static func removeKeyboardCornerRadius() {
        for interval in retryIntervals {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                apply(in: UIApplication.shared.connectedScenes)
            }
        }
    }

    static func flattenCorners(of view: UIView) {
        view.layer.cornerRadius = 0
        view.layer.maskedCorners = []

        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: 0)
        }
    }

    static func resolvedKeyboardCornerRadius() -> CGFloat {
        guard #available(iOS 26.0, *) else {
            return 0
        }

        if measuredKeyboardCornerRadius > 0 {
            return measuredKeyboardCornerRadius
        }

        var detected: CGFloat = 0
        for window in keyboardWindows() {
            collectKeyboardCornerRadius(from: window, into: &detected)
        }
        return detected > 0 ? detected : fallbackKeyboardCornerRadius
    }

    private static func apply(in scenes: Set<UIScene>) {
        let windows = keyboardWindows(in: scenes)
        var detected: CGFloat = 0
        for window in windows {
            collectKeyboardCornerRadius(from: window, into: &detected)
        }
        if detected > 1 {
            measuredKeyboardCornerRadius = detected
        }

        for window in windows {
            removeKeyboardCornerRadius(from: window)
        }
    }

    private static func keyboardWindows() -> [UIWindow] {
        keyboardWindows(in: UIApplication.shared.connectedScenes)
    }

    private static func keyboardWindows(in scenes: Set<UIScene>) -> [UIWindow] {
        scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    private static func removeKeyboardCornerRadius(from view: UIView) {
        if isKeyboardChrome(view) {
            flattenCorners(of: view)
            installCornerFillsIfNeeded(beside: view)
        }

        if view is NotebookAnyViewInputHost {
            view.setNeedsLayout()
        }

        view.subviews.forEach(removeKeyboardCornerRadius(from:))
    }

    private static func installCornerFillsIfNeeded(beside view: UIView) {
        guard #available(iOS 26.0, *), shouldInstallCornerFills(for: view), let parent = view.superview else {
            return
        }

        parent.clipsToBounds = false
        let radius = resolvedKeyboardCornerRadius()
        guard radius > 0 else {
            return
        }

        let leading = reusableCornerFill(in: parent, tag: leadingFillTag, side: .leading)
        let trailing = reusableCornerFill(in: parent, tag: trailingFillTag, side: .trailing)
        leading.radius = radius
        trailing.radius = radius
        leading.frame = CGRect(x: view.frame.minX, y: view.frame.minY, width: radius, height: radius)
        trailing.frame = CGRect(
            x: view.frame.maxX - radius,
            y: view.frame.minY,
            width: radius,
            height: radius
        )
        parent.insertSubview(leading, belowSubview: view)
        parent.insertSubview(trailing, belowSubview: view)
    }

    private static func reusableCornerFill(in parent: UIView, tag: Int, side: KeyboardCornerWedgeView.Side) -> KeyboardCornerWedgeView {
        if let existing = parent.viewWithTag(tag) as? KeyboardCornerWedgeView {
            return existing
        }

        let fill = KeyboardCornerWedgeView(side: side)
        fill.tag = tag
        fill.isUserInteractionEnabled = false
        parent.addSubview(fill)
        return fill
    }

    private static func shouldInstallCornerFills(for view: UIView) -> Bool {
        let className = NSStringFromClass(type(of: view))
        let isKeyboardBody = className.contains("UIKeyboard") || className.contains("_UIKB")
        guard isKeyboardBody else {
            return false
        }

        let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
        return view.bounds.width >= screenWidth - 8 && view.bounds.height > 80
    }

    private static let leadingFillTag = 817_451
    private static let trailingFillTag = 817_452

    private static func collectKeyboardCornerRadius(from view: UIView, into radius: inout CGFloat) {
        if isKeyboardChrome(view), #available(iOS 26.0, *) {
            radius = max(
                radius,
                view.effectiveRadius(corner: .topLeft),
                view.effectiveRadius(corner: .topRight),
                view.layer.cornerRadius
            )
        }

        for subview in view.subviews {
            collectKeyboardCornerRadius(from: subview, into: &radius)
        }
    }

    private static func isKeyboardChrome(_ view: UIView) -> Bool {
        let className = NSStringFromClass(type(of: view))
        return className.contains("UIInputSet")
            || className.contains("UIKeyboard")
            || className.contains("UIRemoteKeyboard")
            || className.contains("_UIKB")
    }
}

/// Fills the square leftover when a full-width accessory sits on a rounded keyboard.
private final class KeyboardCornerWedgeView: UIView {
    enum Side {
        case leading
        case trailing
    }

    var radius: CGFloat = 0 {
        didSet {
            guard oldValue != radius else {
                return
            }
            setNeedsDisplay()
        }
    }

    private let side: Side

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard radius > 0, let context = UIGraphicsGetCurrentContext() else {
            return
        }

        let fillRadius = min(radius, min(rect.width, rect.height))
        let path = UIBezierPath()

        switch side {
        case .leading:
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: fillRadius))
            path.addArc(
                withCenter: CGPoint(x: fillRadius, y: fillRadius),
                radius: fillRadius,
                startAngle: .pi,
                endAngle: .pi * 1.5,
                clockwise: true
            )
            path.close()
        case .trailing:
            path.move(to: CGPoint(x: fillRadius, y: 0))
            path.addLine(to: CGPoint(x: fillRadius, y: fillRadius))
            path.addArc(
                withCenter: CGPoint(x: 0, y: fillRadius),
                radius: fillRadius,
                startAngle: 0,
                endAngle: -.pi / 2,
                clockwise: false
            )
            path.close()
        }

        context.setFillColor(KeyboardCornerRadiusRemover.toolbarFillColor.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    }
}
