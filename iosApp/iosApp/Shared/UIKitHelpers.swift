import SnapKit
import UIKit

// MARK: - SwipeBackNavigationController

/// Screens with an in-content toolbar do not also display UINavigationBar on return.
protocol NavigationCustomToolbarProviding: AnyObject {}

/// Screens that also own full-screen chrome, including the status bar area.
protocol NavigationContentChromeProviding: NavigationCustomToolbarProviding {}

/// UINavigationController subclass that keeps the interactive pop gesture
/// working even when the system navigation bar is hidden.
final class SwipeBackNavigationController: UINavigationController, UIGestureRecognizerDelegate,
    UINavigationControllerDelegate
{
    private static let topChromeBackdropTag = 0x1E6AD1

    override var childForStatusBarStyle: UIViewController? {
        guard topViewController is NavigationContentChromeProviding else { return nil }
        return topViewController
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        BookshelfRootView.statusBarStyle(for: traitCollection)
    }

    override var childForStatusBarHidden: UIViewController? {
        topViewController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        topViewController
    }

    override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        topViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = AndroidReplicaTheme.toolbarBackground
        appearance.titleTextAttributes = [.foregroundColor: AndroidReplicaTheme.toolbarText]
        appearance.largeTitleTextAttributes = [.foregroundColor: AndroidReplicaTheme.toolbarText]
        appearance.shadowColor = .clear
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
        navigationBar.tintColor = AndroidReplicaTheme.toolbarText
        delegate = self
        interactivePopGestureRecognizer?.delegate = self
    }

    func navigationController(
        _: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        if viewController is NavigationCustomToolbarProviding {
            setNavigationBarHidden(true, animated: animated)
        }
        guard !(viewController is NavigationContentChromeProviding) else { return }
        viewController.loadViewIfNeeded()
        guard let contentView = viewController.viewIfLoaded else { return }
        guard !contentView.subviews.contains(where: { $0.tag == Self.topChromeBackdropTag }) else { return }
        let backdrop = UIView()
        backdrop.tag = Self.topChromeBackdropTag
        backdrop.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isUserInteractionEnabled = false
        backdrop.isAccessibilityElement = false
        backdrop.accessibilityElementsHidden = true
        contentView.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
        ])
    }

    func navigationController(
        _: UINavigationController, didShow viewController: UIViewController, animated _: Bool
    ) {
        guard topViewController === viewController else { return }
        // A source's viewWillDisappear can restore an old bar state during a cancelled pop.
        if viewController is NavigationCustomToolbarProviding {
            setNavigationBarHidden(true, animated: false)
        }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        guard viewControllers.count > 1, let topViewController,
            topViewController.canPerformNavigationAction
        else { return false }
        guard transitionCoordinator == nil,
            topViewController.transitionCoordinator == nil,
            presentedViewController == nil,
            topViewController.presentedViewController == nil,
            !isBeingPresented,
            !isBeingDismissed,
            !topViewController.isBeingPresented,
            !topViewController.isBeingDismissed
        else { return false }
        return (topViewController as? NavigationBackActionHandling)?.interceptNavigationBackGesture() != true
    }
}

// MARK: - UIViewController helpers

extension UIViewController {
    /// Tab roots are children of the navigation stack's home container.
    var isVisibleInNavigationStack: Bool {
        guard viewIfLoaded?.window != nil, let navigation = navigationController else { return false }
        var candidate: UIViewController? = self
        while let controller = candidate, controller !== navigation {
            if navigation.topViewController === controller { return true }
            candidate = controller.parent
        }
        return false
    }

    /// Unlike stack membership, starting a new user navigation must not cross another presentation.
    var canPerformNavigationAction: Bool {
        guard isVisibleInNavigationStack,
            UIApplication.shared.applicationState == .active,
            let window = viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive,
            let navigation = navigationController, navigation.transitionCoordinator == nil
        else { return false }
        var candidate: UIViewController? = self
        while let controller = candidate {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.presentedViewController == nil,
                controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false,
                (controller.viewIfLoaded?.alpha ?? 0) > 0
            else { return false }
            if controller === navigation { return true }
            candidate = controller.parent
        }
        return false
    }

    private static let transientMessageTag = 0x1E6AD0
    private static let transientMessageBottomConstraintIdentifier = "legado.transient.message.bottom"

    func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.Common.loadFailedTitle,
            message: error.userFacingMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
        topmostPresentedViewController.present(alert, animated: true)
    }

    func presentNotImplemented(feature: String, message: String? = nil) {
        let alert = UIAlertController(
            title: L10n.Common.unavailableTitle,
            message: message ?? String(format: L10n.Common.notImplementedMessage, feature),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
        topmostPresentedViewController.present(alert, animated: true)
    }

    var topmostPresentedViewController: UIViewController {
        var vc: UIViewController = self
        while let presented = vc.presentedViewController {
            vc = presented
        }
        return vc
    }

    func showTransientMessage(_ message: String, duration: TimeInterval = 2.4) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        if let existing = view.viewWithTag(Self.transientMessageTag) {
            existing.removeFromSuperview()
        }

        let banner = TransientMessageView(message: trimmed)
        banner.tag = Self.transientMessageTag
        banner.alpha = 0
        banner.transform = CGAffineTransform(translationX: 0, y: 12)
        view.addSubview(banner)

        let bottomInset = max(view.safeAreaInsets.bottom, 16) + 24
        let bottomConstraint = banner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottomInset)
        bottomConstraint.identifier = Self.transientMessageBottomConstraintIdentifier

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            bottomConstraint,
        ])

        UIView.animate(withDuration: 0.2) {
            banner.alpha = 1
            banner.transform = .identity
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak banner] in
            guard let banner, banner.superview != nil else { return }
            UIView.animate(withDuration: 0.2, animations: {
                banner.alpha = 0
                banner.transform = CGAffineTransform(translationX: 0, y: 8)
            }, completion: { _ in
                banner.removeFromSuperview()
            })
        }
    }

    func configuredForDrillDownPresentation() -> Self {
        hidesBottomBarWhenPushed = true
        navigationItem.largeTitleDisplayMode = .never
        return self
    }

    func wrappedInReaderBottomSheet(title: String? = nil, fixedHeight: CGFloat? = nil) -> UIViewController {
        if let title {
            self.title = title
        }
        let controller = ReaderBottomSheetNavigationController(contentViewController: self)
        let preferredHeight = fixedHeight ?? preferredContentSize.height
        if preferredHeight > 0 {
            controller.preferredContentSize = CGSize(width: preferredContentSize.width, height: preferredHeight)
            controller.preferredSheetHeight = preferredHeight
        }
        return controller
    }
}

private final class TransientMessageView: UIVisualEffectView {
    private let label = UILabel()

    init(message: String) {
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        clipsToBounds = true

        contentView.backgroundColor = UIColor.black.withAlphaComponent(0.22)

        label.text = message
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center

        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class LegacyTitleBarView: UIView {
    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let hairlineView = UIView()
    private let leftStackView = UIStackView()
    private let rightStackView = UIStackView()
    private let titleLabel = UILabel()
    private let centerContainer = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
    }

    func setCenterView(_ view: UIView?, alignment: NSTextAlignment = .center) {
        centerContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view else {
            titleLabel.isHidden = false
            return
        }
        titleLabel.isHidden = true
        centerContainer.addSubview(view)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.greaterThanOrEqualTo(30)
        }
        if alignment == .left || alignment == .natural {
            centerContainer.snp.remakeConstraints { make in
                make.centerY.equalTo(leftStackView)
                make.leading.equalTo(leftStackView.snp.trailing).offset(8)
                make.trailing.lessThanOrEqualTo(rightStackView.snp.leading).offset(-8)
                make.height.greaterThanOrEqualTo(30)
                make.top.greaterThanOrEqualToSuperview().offset(8)
                make.bottom.lessThanOrEqualToSuperview().inset(8)
            }
        }
    }

    func setLeftViews(_ views: [UIView]) {
        for stackSubview in leftStackView.arrangedSubviews {
            leftStackView.removeArrangedSubview(stackSubview)
            stackSubview.removeFromSuperview()
        }
        views.forEach { leftStackView.addArrangedSubview($0) }
    }

    func setRightViews(_ views: [UIView]) {
        for stackSubview in rightStackView.arrangedSubviews {
            rightStackView.removeArrangedSubview(stackSubview)
            stackSubview.removeFromSuperview()
        }
        views.forEach { rightStackView.addArrangedSubview($0) }
    }

    private func configureView() {
        backgroundColor = .clear
        backgroundView.contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.86)
        addSubview(backgroundView)
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        for item in [leftStackView, rightStackView] {
            item.axis = .horizontal
            item.spacing = 8
            item.alignment = .center
        }

        addSubview(leftStackView)
        addSubview(rightStackView)
        addSubview(titleLabel)
        addSubview(centerContainer)
        addSubview(hairlineView)

        leftStackView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(10)
            make.height.greaterThanOrEqualTo(28)
        }

        rightStackView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(10)
            make.height.greaterThanOrEqualTo(28)
        }

        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(leftStackView)
            make.leading.greaterThanOrEqualTo(leftStackView.snp.trailing).offset(12)
            make.trailing.lessThanOrEqualTo(rightStackView.snp.leading).offset(-12)
        }

        centerContainer.snp.makeConstraints { make in
            make.centerY.equalTo(leftStackView)
            make.leading.greaterThanOrEqualTo(leftStackView.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualTo(rightStackView.snp.leading).offset(-8)
            make.centerX.equalToSuperview()
            make.height.greaterThanOrEqualTo(30)
            make.top.greaterThanOrEqualToSuperview().offset(8)
            make.bottom.lessThanOrEqualToSuperview().inset(8)
        }

        hairlineView.backgroundColor = .separator.withAlphaComponent(0.35)
        hairlineView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
    }
}

final class LegacyRootScaffoldView: UIView {
    let titleBarView = LegacyTitleBarView()
    let contentView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(titleBarView)
        addSubview(contentView)

        titleBarView.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(safeAreaLayoutGuide)
            make.height.equalTo(AppUI.Layout.legacyTitleBarHeight)
        }

        contentView.snp.makeConstraints { make in
            make.top.equalTo(titleBarView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

func makeLegacyBarButton(
    title: String? = nil,
    imageSystemName: String? = nil,
    target: Any?,
    action: Selector
) -> UIButton {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.plain()
    if let imageSystemName {
        configuration.image = UIImage(systemName: imageSystemName)
    }
    configuration.title = title
    configuration.imagePadding = 6
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    button.configuration = configuration
    button.addTarget(target, action: action, for: .touchUpInside)
    return button
}

final class ContentStateView: UIView {
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stackView = UIStackView()
    private var actionHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isHidden = true

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = AppUI.Spacing.small
        stackView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.configuration = .borderedProminent()
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)
        actionButton.isHidden = true

        stackView.addArrangedSubview(activityIndicator)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(actionButton)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: AppUI.Spacing.xLarge),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -AppUI.Spacing.xLarge),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTestingIdentifier(_ identifier: String) {
        accessibilityIdentifier = identifier
        accessibilityValue = "hidden"
        titleLabel.accessibilityIdentifier = "\(identifier).title"
        messageLabel.accessibilityIdentifier = "\(identifier).message"
        actionButton.accessibilityIdentifier = "\(identifier).action"
        activityIndicator.accessibilityIdentifier = "\(identifier).loading"
    }

    func showLoading(title: String = L10n.Common.loadingTitle, message: String) {
        isHidden = false
        titleLabel.text = title
        messageLabel.text = message
        activityIndicator.isHidden = false
        activityIndicator.startAnimating()
        actionButton.isHidden = true
        actionHandler = nil
        accessibilityValue = "loading"
    }

    func showMessage(
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        isHidden = false
        titleLabel.text = title
        messageLabel.text = message ?? ""
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        actionButton.isHidden = actionTitle == nil
        actionButton.setTitle(actionTitle, for: .normal)
        actionHandler = action
        accessibilityValue = "message"
    }

    func hide() {
        isHidden = true
        activityIndicator.stopAnimating()
        actionHandler = nil
        accessibilityValue = "hidden"
    }

    @objc private func handleAction() {
        actionHandler?()
    }
}

extension UITableView {
    func setPlaceholder(_ text: String?) {
        guard let text, !text.isEmpty else {
            backgroundView = nil
            return
        }

        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        backgroundView = label
    }
}

extension UICollectionView {
    func setPlaceholder(_ text: String?) {
        guard let text, !text.isEmpty else {
            backgroundView = nil
            return
        }

        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        backgroundView = label
    }
}

extension UIColor {
    convenience init?(hex: String) {
        let sanitized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 8,
              let value = UInt64(sanitized, radix: 16)
        else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if sanitized.count == 8 {
            alpha = CGFloat((value & 0xFF00_0000) >> 24) / 255
            red = CGFloat((value & 0x00FF_0000) >> 16) / 255
            green = CGFloat((value & 0x0000_FF00) >> 8) / 255
            blue = CGFloat(value & 0x0000_00FF) / 255
        } else {
            red = CGFloat((value & 0xFF0000) >> 16) / 255
            green = CGFloat((value & 0x00FF00) >> 8) / 255
            blue = CGFloat(value & 0x0000FF) / 255
            alpha = 1
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    var perceivedBrightness: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            var white: CGFloat = 0
            guard getWhite(&white, alpha: &alpha) else { return 0 }
            return white
        }
        return ((red * 299) + (green * 587) + (blue * 114)) / 1000
    }
}

extension Bundle {
    func legadoDefaultBookSourcesPayload() -> String? {
        guard let url = url(forResource: "defaultBookSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return payload
    }

    func legadoDefaultRssSourcesPayload() -> String? {
        guard let url = url(forResource: "defaultRssSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return payload
    }
}

extension Error {
    var userFacingMessage: String {
        let message = localizedDescription
        switch message {
        case "XPath is not implemented on iOS yet. The original Android stack relies on JsoupXpath, and no KMP-compatible XPath library has been adopted for iosMain.":
            return L10n.Errors.xpathUnsupported
        case "AnalyzeUrl webView requests are not implemented in shared execution yet":
            return L10n.Errors.webViewUnsupported
        case "AnalyzeUrl proxy requests are not implemented in shared execution yet":
            return L10n.Errors.proxyUnsupported
        case "AnalyzeUrl media requests are not implemented in shared execution yet":
            return L10n.Errors.mediaUnsupported
        case "Source URL is empty":
            return L10n.Errors.sourceUrlEmpty
        case "Source payload is empty":
            return L10n.Errors.sourcePayloadEmpty
        case "Source URL must start with http:// or https://":
            return L10n.Errors.sourceUrlInvalid
        case "No valid book sources found in payload":
            return L10n.Errors.sourcePayloadInvalid
        case "WebDAV not configured":
            return L10n.WebDav.notConfigured
        default:
            if message.contains("Failed to parse book source payload") {
                return L10n.Errors.sourcePayloadParse
            }
            return message
        }
    }
}

extension String {
    var sanitizedDisplayText: String {
        var value = self
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        value = value.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
