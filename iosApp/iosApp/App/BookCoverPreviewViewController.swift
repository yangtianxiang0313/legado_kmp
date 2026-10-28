import UIKit

final class BookCoverPreviewViewController: UIViewController, NavigationContentChromeProviding {
    override var preferredStatusBarStyle: UIStatusBarStyle {
        let background = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return .default }
        return red * 0.299 + green * 0.587 + blue * 0.114 > 0.5 ? .darkContent : .lightContent
    }

    private enum LoadingState: Equatable {
        case idle, loading, loaded, failed
    }

    private let loadImage: () async -> UIImage?
    private let imageContainer = UIView()
    private let statusStack = UIStackView()
    private let statusScrollView = UIScrollView()
    private let statusContentView = UIView()
    private let closeButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var fullImageBottom: NSLayoutConstraint!
    private var statusImageBottom: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var imageConstraints: [NSLayoutConstraint] = []
    private var imageTask: Task<Void, Never>?
    private var generation = UUID()
    private var imagePreview: ImagePreviewViewController?
    private var displayedImage: UIImage?
    private var loadingState: LoadingState = .idle
    private var isPreviewVisible = false
    private var isClosing = false

    init(image: UIImage?, loadImage: @escaping () async -> UIImage?) {
        displayedImage = BookCoverPreviewViewController.previewableImage(image)
        self.loadImage = loadImage
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { imageTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityViewIsModal = true
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = AndroidReplicaTheme.primaryText
        closeButton.accessibilityLabel = "关闭"
        closeButton.accessibilityIdentifier = "bookDetail.coverPreview.close"
        closeButton.addTarget(self, action: #selector(closePreview), for: .touchUpInside)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.tintColor = AndroidReplicaTheme.primaryText
        retryButton.accessibilityLabel = L10n.Common.retry
        retryButton.accessibilityIdentifier = "bookDetail.coverPreview.retry"
        retryButton.addTarget(self, action: #selector(retryLoading), for: .touchUpInside)
        retryButton.isHidden = true
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        statusLabel.accessibilityIdentifier = "bookDetail.coverPreview.status"
        spinner.color = AndroidReplicaTheme.primaryText
        spinner.hidesWhenStopped = true
        configureLayout()
        if let displayedImage { showImage(displayedImage) }
        updateLoadingState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isClosing = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing, !isBeingDismissed else { return }
        isPreviewVisible = true
        if loadingState == .idle { loadCover() }
        UIAccessibility.post(notification: .screenChanged, argument: imagePreview?.view ?? closeButton)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPreviewVisible = false
        cancelLoading()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let preferredHeight = max(44, ceil(statusLabel.font.lineHeight)) + 16
        let maximumHeight = max(60, floor(view.safeAreaLayoutGuide.layoutFrame.height * 0.25))
        statusHeight.constant = min(preferredHeight, maximumHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsStatusBarAppearanceUpdate()
        viewIfLoaded?.setNeedsLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        closePreview()
        return true
    }

    private func configureLayout() {
        imageContainer.clipsToBounds = true
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 8
        statusScrollView.contentInsetAdjustmentBehavior = .never
        statusScrollView.showsHorizontalScrollIndicator = false
        statusScrollView.alwaysBounceVertical = false
        statusScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusScrollView)
        statusStack.addArrangedSubview(retryButton)
        statusScrollView.addSubview(statusContentView)
        statusContentView.addSubview(statusLabel)
        for item in [imageContainer, statusStack, closeButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [spinner, statusScrollView, statusContentView, statusLabel, retryButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
        }

        fullImageBottom = imageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        statusImageBottom = imageContainer.bottomAnchor.constraint(equalTo: statusStack.topAnchor, constant: -8)
        statusHeight = statusStack.heightAnchor.constraint(equalToConstant: 60)
        let preferredContentHeight = statusContentView.heightAnchor.constraint(equalTo: statusScrollView.frameLayoutGuide.heightAnchor)
        preferredContentHeight.priority = .defaultLow
        let spinnerWidth = spinner.widthAnchor.constraint(equalToConstant: 24)
        let retryWidth = retryButton.widthAnchor.constraint(equalToConstant: 44)
        spinnerWidth.priority = UILayoutPriority(999)
        retryWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            imageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            imageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fullImageBottom,
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            statusStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            statusHeight,
            spinnerWidth,
            spinner.heightAnchor.constraint(equalToConstant: 24),
            statusScrollView.heightAnchor.constraint(equalTo: statusStack.heightAnchor, constant: -16),
            statusContentView.topAnchor.constraint(equalTo: statusScrollView.contentLayoutGuide.topAnchor),
            statusContentView.leadingAnchor.constraint(equalTo: statusScrollView.contentLayoutGuide.leadingAnchor),
            statusContentView.trailingAnchor.constraint(equalTo: statusScrollView.contentLayoutGuide.trailingAnchor),
            statusContentView.bottomAnchor.constraint(equalTo: statusScrollView.contentLayoutGuide.bottomAnchor),
            statusContentView.widthAnchor.constraint(equalTo: statusScrollView.frameLayoutGuide.widthAnchor),
            statusContentView.heightAnchor.constraint(greaterThanOrEqualTo: statusScrollView.frameLayoutGuide.heightAnchor),
            preferredContentHeight,
            statusLabel.topAnchor.constraint(greaterThanOrEqualTo: statusContentView.topAnchor),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: statusContentView.bottomAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusContentView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusContentView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: statusContentView.trailingAnchor),
            retryWidth,
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func loadCover() {
        guard isPreviewVisible, !isClosing, !isBeingDismissed else { return }
        cancelLoading()
        let id = generation
        loadingState = .loading
        updateLoadingState()
        imageTask = Task { @MainActor [weak self, loadImage] in
            let loaded = await loadImage()
            guard let self, !Task.isCancelled, self.generation == id, self.isPreviewVisible,
                self.viewIfLoaded?.window != nil, !self.isClosing, !self.isBeingDismissed
            else { return }
            self.imageTask = nil
            if let image = Self.previewableImage(loaded) {
                let hadImage = self.imagePreview != nil
                self.showImage(image)
                self.loadingState = .loaded
                self.updateLoadingState()
                if !hadImage {
                    UIAccessibility.post(notification: .screenChanged, argument: self.imagePreview?.view)
                }
            } else {
                self.loadingState = .failed
                self.updateLoadingState()
                UIAccessibility.post(notification: .layoutChanged, argument: self.statusLabel)
            }
        }
    }

    private func showImage(_ image: UIImage) {
        guard imagePreview == nil || displayedImage !== image else { return }
        if let previous = imagePreview {
            previous.willMove(toParent: nil)
            NSLayoutConstraint.deactivate(imageConstraints)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
        let controller = ImagePreviewViewController(
            image: image,
            onClose: { [weak self] in
                self?.closePreview()
            })
        displayedImage = image
        imagePreview = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = AndroidReplicaTheme.background
        controller.view.accessibilityIdentifier = "bookDetail.coverPreview.image"
        imageContainer.addSubview(controller.view)
        imageConstraints = [
            controller.view.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(imageConstraints)
        controller.didMove(toParent: self)
        // The child owns the sole close control while an actual image is visible.
        closeButton.isHidden = true
    }

    private func updateLoadingState() {
        let showsStatus = loadingState == .loading || loadingState == .failed
        fullImageBottom.isActive = false
        statusImageBottom.isActive = false
        statusStack.isHidden = !showsStatus
        statusImageBottom.isActive = showsStatus
        fullImageBottom.isActive = !showsStatus
        retryButton.isHidden = loadingState != .failed
        statusLabel.text = loadingState == .failed ? "封面加载失败" : "封面加载中"
        statusScrollView.setContentOffset(.zero, animated: false)
        if loadingState == .loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        closeButton.isHidden = imagePreview != nil
    }

    private func cancelLoading() {
        generation = UUID()
        imageTask?.cancel()
        imageTask = nil
        if loadingState == .loading {
            loadingState = .idle
            updateLoadingState()
        }
    }

    private static func previewableImage(_ image: UIImage?) -> UIImage? {
        guard let image, !image.isSymbolImage, image.size.width.isFinite, image.size.height.isFinite,
            image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }

    @objc private func retryLoading() { loadCover() }

    @objc private func closePreview() {
        guard !isClosing, !isBeingDismissed else { return }
        isClosing = true
        isPreviewVisible = false
        cancelLoading()
        dismiss(animated: true)
    }
}
