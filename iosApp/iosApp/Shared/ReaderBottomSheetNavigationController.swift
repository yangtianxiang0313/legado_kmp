import UIKit

final class ReaderBottomSheetNavigationController: UIViewController, UIViewControllerTransitioningDelegate {
    enum ChromeStyle {
        case standard
        case androidPanel
    }

    var preferredSheetHeight: CGFloat = 0 {
        didSet {
            preferredContentSize.height = preferredSheetHeight
        }
    }

    private let contentViewController: UIViewController
    private let chromeStyle: ChromeStyle
    private let chromeView = UIView()
    private let dragHandleView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let hairlineView = UIView()

    init(contentViewController: UIViewController, chromeStyle: ChromeStyle = .standard) {
        self.contentViewController = contentViewController
        self.chromeStyle = chromeStyle
        super.init(nibName: nil, bundle: nil)
        configureReaderBottomSheet()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentViewController.loadViewIfNeeded()
        if chromeStyle == .standard {
            configureChrome()
        } else {
            preferredContentSize = contentViewController.preferredContentSize
            view.accessibilityViewIsModal = true
        }
        embedContent()
        view.clipsToBounds = true
        view.backgroundColor = chromeStyle == .standard ? AndroidReplicaTheme.background : contentViewController.view.backgroundColor
        view.layer.cornerRadius = chromeStyle == .standard ? 18 : 0
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true
    }

    private func configureReaderBottomSheet() {
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    private func configureChrome() {
        contentViewController.loadViewIfNeeded()

        chromeView.backgroundColor = AndroidReplicaTheme.background
        dragHandleView.backgroundColor = AndroidReplicaTheme.secondaryText.withAlphaComponent(0.36)
        dragHandleView.layer.cornerRadius = 2
        titleLabel.text = contentViewController.title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        closeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeButton.tintColor = AndroidReplicaTheme.primaryText
        closeButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        closeButton.addTarget(self, action: #selector(dismissSheet), for: .touchUpInside)
        hairlineView.backgroundColor = AndroidReplicaTheme.divider

        for item in [chromeView, dragHandleView, titleLabel, closeButton, hairlineView] {
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(chromeView)
        chromeView.addSubview(dragHandleView)
        chromeView.addSubview(titleLabel)
        chromeView.addSubview(closeButton)
        chromeView.addSubview(hairlineView)

        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: view.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeView.heightAnchor.constraint(equalToConstant: 54),

            dragHandleView.topAnchor.constraint(equalTo: chromeView.topAnchor, constant: 8),
            dragHandleView.centerXAnchor.constraint(equalTo: chromeView.centerXAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: 42),
            dragHandleView.heightAnchor.constraint(equalToConstant: 4),

            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            closeButton.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -60),

            hairlineView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            hairlineView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            hairlineView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            hairlineView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    private func embedContent() {
        addChild(contentViewController)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentViewController.view)
        NSLayoutConstraint.activate([
            contentViewController.view.topAnchor.constraint(equalTo: chromeStyle == .standard ? chromeView.bottomAnchor : view.topAnchor),
            contentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentViewController.didMove(toParent: self)
    }

    @objc private func dismissSheet() {
        dismiss(animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard chromeStyle == .androidPanel else { return super.accessibilityPerformEscape() }
        dismiss(animated: true)
        return true
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard chromeStyle == .androidPanel else { return }
        preferredContentSize = contentViewController.preferredContentSize
        presentationController?.containerView?.setNeedsLayout()
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source _: UIViewController
    ) -> UIPresentationController? {
        ReaderBottomSheetPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            fixedHeight: preferredSheetHeight,
            isAndroidPanel: chromeStyle == .androidPanel
        )
    }

    func animationController(
        forPresented _: UIViewController,
        presenting _: UIViewController,
        source _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        ReaderBottomSheetAnimator(isPresenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        ReaderBottomSheetAnimator(isPresenting: false)
    }
}

private final class ReaderBottomSheetPresentationController: UIPresentationController {
    private let fixedHeight: CGFloat
    private let isAndroidPanel: Bool
    private let outsideTapView = UIView()

    init(presentedViewController: UIViewController, presenting presentingViewController: UIViewController?, fixedHeight: CGFloat, isAndroidPanel: Bool) {
        self.fixedHeight = fixedHeight
        self.isAndroidPanel = isAndroidPanel
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
        outsideTapView.backgroundColor = .clear
        outsideTapView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissPresentedController)))
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        let safeArea = containerView.safeAreaInsets
        let availableHeight = max(containerView.bounds.height - safeArea.top, isAndroidPanel ? 0 : 220)
        let contentHeight = fixedHeight > 0 ? fixedHeight : presentedViewController.preferredContentSize.height
        // ReadStyleDialog is wrap-content; the system's bottom exclusion is not content padding.
        let resolvedHeight =
            isAndroidPanel
            ? min(max(contentHeight, 0) + safeArea.bottom, availableHeight)
            : min(max(contentHeight, 220), availableHeight)
        return CGRect(
            x: 0,
            y: containerView.bounds.height - resolvedHeight,
            width: containerView.bounds.width,
            height: resolvedHeight
        )
    }

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        outsideTapView.frame = containerView.bounds
        outsideTapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.insertSubview(outsideTapView, at: 0)
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            if !self.isAndroidPanel {
                self.presentedView?.backgroundColor = AndroidReplicaTheme.background
            }
        })
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(
            alongsideTransition: { _ in
                self.outsideTapView.alpha = 0
            },
            completion: { _ in
                self.outsideTapView.removeFromSuperview()
            })
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        outsideTapView.frame = containerView?.bounds ?? .zero
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    @objc private func dismissPresentedController() {
        presentedViewController.dismiss(animated: true)
    }
}

private final class ReaderBottomSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.18
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key) else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView
        if isPresenting {
            containerView.addSubview(controller.view)
        }

        let finalFrame = transitionContext.finalFrame(for: controller)
        let hiddenFrame = finalFrame.offsetBy(dx: 0, dy: finalFrame.height)
        controller.view.frame = isPresenting ? hiddenFrame : finalFrame

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                controller.view.frame = self.isPresenting ? finalFrame : hiddenFrame
            },
            completion: { finished in
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        )
    }
}
