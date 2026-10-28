import UIKit
import shared

@MainActor
final class MangaPageCell: UICollectionViewCell {
    var hasLoadedImage: Bool { imageView.hasPresentation }
    static let reuseIdentifier = "MangaPageCell"
    private let imageView = MangaImageSurfaceView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let retryButton = UIButton(type: .system)
    private let status = UIStackView()
    private var statusCenterX: NSLayoutConstraint?
    private var statusCenterY: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?
    private var revision = UUID()
    private var retry: (() -> Void)?
    private var resume: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.accessibilityTraits = .image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        status.axis = .vertical
        status.alignment = .center
        status.spacing = 12
        status.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .lightGray
        message.textAlignment = .center
        message.numberOfLines = 3
        var configuration = UIButton.Configuration.plain()
        configuration.title = "重试"
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 6
        retryButton.configuration = configuration
        retryButton.tintColor = .white
        retryButton.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        [spinner, message, retryButton].forEach { status.addArrangedSubview($0) }
        contentView.addSubview(status)
        let centerX = status.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        let centerY = status.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        statusCenterX = centerX
        statusCenterY = centerY
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            centerX, centerY,
            status.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -32),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { imageTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshVisibleTiles()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        imageView.setPresentation(nil)
        imageView.accessibilityLabel = nil
        retry = nil
        resume = nil
        imageView.onRetry = nil
    }

    func configure(
        page: MangaPage, pipeline: MangaImagePipeline, pixelWidth: Int,
        displayStyle: MangaImageDisplayStyle = .original,
        colorFilter: MangaColorFilter = .init(),
        onAspectRatio: @escaping (CGFloat) -> Void
    ) {
        cancelLoad()
        imageView.setPresentation(nil)
        imageView.accessibilityLabel = "第\(Int(page.index) + 1)张，共\(page.imageCount)张"
        retry = { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            self.start(
                page: page, pipeline: pipeline, pixelWidth: pixelWidth, refresh: true,
                displayStyle: displayStyle, colorFilter: colorFilter, onAspectRatio: onAspectRatio)
        }
        imageView.onRetry = { [weak self] in self?.retryImage() }
        resume = { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            self.start(
                page: page, pipeline: pipeline, pixelWidth: pixelWidth, refresh: false,
                displayStyle: displayStyle, colorFilter: colorFilter, onAspectRatio: onAspectRatio)
        }
        start(
            page: page, pipeline: pipeline, pixelWidth: pixelWidth, refresh: false,
            displayStyle: displayStyle, colorFilter: colorFilter, onAspectRatio: onAspectRatio)
    }

    func resumeLoad() {
        imageView.resume()
        if imageTask == nil, !imageView.hasPresentation { resume?() }
    }

    func refreshVisibleTiles() {
        imageView.refreshVisibleTiles()
        guard !status.isHidden, let window else { return }
        var visible = contentView.convert(window.bounds, from: window).intersection(contentView.bounds)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds || view is UIScrollView {
                visible = visible.intersection(contentView.convert(view.bounds, from: view))
            }
            ancestor = view.superview
        }
        guard !visible.isNull, !visible.isInfinite, visible.width > 0, visible.height > 0 else { return }
        let x = visible.midX - contentView.bounds.midX
        let y = visible.midY - contentView.bounds.midY
        if statusCenterX?.constant != x { statusCenterX?.constant = x }
        if statusCenterY?.constant != y { statusCenterY?.constant = y }
    }

    func cancelLoad() {
        revision = UUID()
        imageTask?.cancel()
        imageTask = nil
        spinner.stopAnimating()
        imageView.suspend()
    }

    private func start(
        page: MangaPage, pipeline: MangaImagePipeline, pixelWidth: Int, refresh: Bool,
        displayStyle: MangaImageDisplayStyle,
        colorFilter: MangaColorFilter,
        onAspectRatio: @escaping (CGFloat) -> Void
    ) {
        cancelLoad()
        imageView.setPresentation(nil)
        imageView.resume()
        let token = revision
        status.isHidden = false
        retryButton.isHidden = true
        message.text = "第\(Int(page.index) + 1)张"
        spinner.startAnimating()
        refreshVisibleTiles()
        imageTask = Task { [weak self] in
            do {
                let image = try await pipeline.loadPresentation(
                    imageURL: page.mImageUrl, pixelWidth: pixelWidth, refresh: refresh,
                    displayStyle: displayStyle, colorFilter: colorFilter)
                try Task.checkCancellation()
                guard let self, self.revision == token else { return }
                self.imageTask = nil
                self.imageView.setPresentation(image)
                self.status.isHidden = true
                self.spinner.stopAnimating()
                if image.pixelSize.width > 0 { onAspectRatio(image.pixelSize.height / image.pixelSize.width) }
            } catch {
                guard let self, self.revision == token else { return }
                self.imageTask = nil
                self.spinner.stopAnimating()
                guard !Task.isCancelled, !(error is CancellationError) else {
                    self.status.isHidden = true
                    return
                }
                self.message.text = "第\(Int(page.index) + 1)张加载失败"
                self.retryButton.isHidden = false
                self.refreshVisibleTiles()
            }
        }
    }

    @objc private func retryImage() { retry?() }
}
