import UIKit

@MainActor
final class MangaImageZoomViewController: UIViewController, UIScrollViewDelegate {
    private let imageURL: String
    private let pipeline: MangaImagePipeline
    private let displayStyle: MangaImageDisplayStyle
    private let colorFilter: MangaColorFilter
    private let scroll = UIScrollView()
    private let surface = MangaImageSurfaceView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retry = UIButton(type: .system)
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var previousBounds = CGSize.zero
    private var hasFitImage = false
    private var pixelSize = CGSize.zero

    init(
        imageURL: String, title: String, pipeline: MangaImagePipeline,
        displayStyle: MangaImageDisplayStyle = .original,
        colorFilter: MangaColorFilter = .init()
    ) {
        self.imageURL = imageURL
        self.pipeline = pipeline
        self.displayStyle = displayStyle
        self.colorFilter = colorFilter
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { task?.cancel() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        scroll.delegate = self
        scroll.backgroundColor = .black
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        surface.accessibilityLabel = title
        surface.onRetry = { [weak self] in self?.load(refresh: true) }
        scroll.addSubview(surface)
        view.addSubview(scroll)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "图片加载失败，重试"
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 8
        retry.configuration = configuration
        retry.tintColor = .white
        retry.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.addTarget(self, action: #selector(retryImage), for: .touchUpInside)
        view.addSubview(retry)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retry.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retry.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retry.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomImage(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        surface.resume()
        if !surface.hasPresentation, task == nil { load(refresh: false) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelLoad()
        surface.suspend()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.bounds.size != previousBounds {
            previousBounds = scroll.bounds.size
            fitImage()
        }
        surface.refreshVisibleTiles()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        surface.refreshVisibleTiles()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.refreshVisibleTiles() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        surface.refreshVisibleTiles()
    }

    private func load(refresh: Bool) {
        cancelLoad()
        surface.resume()
        let token = revision
        spinner.startAnimating()
        retry.isHidden = true
        let width = max(2048, Int(view.bounds.width * (view.window?.screen.scale ?? UIScreen.main.scale) * 2))
        task = Task { [weak self, pipeline, imageURL, displayStyle, colorFilter] in
            do {
                let presentation = try await pipeline.loadPresentation(
                    imageURL: imageURL, pixelWidth: width, refresh: refresh,
                    displayStyle: displayStyle, colorFilter: colorFilter)
                try Task.checkCancellation()
                guard let self, self.revision == token else { return }
                self.task = nil
                let preservesFit = self.surface.hasPresentation && self.pixelSize == presentation.pixelSize
                self.pixelSize = presentation.pixelSize
                self.surface.setPresentation(presentation)
                if !preservesFit { self.hasFitImage = false }
                self.fitImage()
                self.spinner.stopAnimating()
            } catch {
                guard let self, self.revision == token else { return }
                self.task = nil
                self.spinner.stopAnimating()
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.retry.isHidden = false
            }
        }
    }

    private func cancelLoad() {
        revision = UUID()
        task?.cancel()
        task = nil
        spinner.stopAnimating()
    }

    private func fitImage() {
        guard surface.hasPresentation, pixelSize.width.isFinite, pixelSize.height.isFinite,
            pixelSize.width > 0, pixelSize.height > 0, scroll.bounds.width > 0, scroll.bounds.height > 0
        else { return }
        let previousCenter = scroll.convert(
            CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: surface)
        let previousMinimum = scroll.minimumZoomScale
        let wasZoomed = hasFitImage && scroll.zoomScale > previousMinimum * 1.02
        let zoomRatio = previousMinimum > 0 ? scroll.zoomScale / previousMinimum : 1
        let minimum = min(scroll.bounds.width / pixelSize.width, scroll.bounds.height / pixelSize.height)
        scroll.minimumZoomScale = min(minimum, 1)
        scroll.maximumZoomScale = max(minimum * 8, 1)
        scroll.zoomScale = 1
        surface.frame = CGRect(origin: .zero, size: pixelSize)
        scroll.contentSize = pixelSize
        scroll.minimumZoomScale = minimum
        scroll.zoomScale = wasZoomed ? min(scroll.maximumZoomScale, minimum * zoomRatio) : minimum
        hasFitImage = true
        centerImage()
        if wasZoomed {
            let x = min(max(0, previousCenter.x), pixelSize.width) * scroll.zoomScale - scroll.bounds.width / 2
            let y = min(max(0, previousCenter.y), pixelSize.height) * scroll.zoomScale - scroll.bounds.height / 2
            scroll.contentOffset = CGPoint(
                x: min(
                    max(-scroll.contentInset.left, x),
                    max(-scroll.contentInset.left, scroll.contentSize.width - scroll.bounds.width)),
                y: min(
                    max(-scroll.contentInset.top, y),
                    max(-scroll.contentInset.top, scroll.contentSize.height - scroll.bounds.height)))
        }
        surface.refreshVisibleTiles()
    }

    private func centerImage() {
        scroll.contentInset = UIEdgeInsets(
            top: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2),
            left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2),
            bottom: 0, right: 0)
    }

    @objc private func zoomImage(_ gesture: UITapGestureRecognizer) {
        guard surface.hasPresentation else { return }
        if scroll.zoomScale > scroll.minimumZoomScale * 1.1 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            let scale = min(scroll.maximumZoomScale, max(1, scroll.minimumZoomScale * 3))
            let location = gesture.location(in: surface)
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(
                to: CGRect(
                    x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height),
                animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    @objc private func retryImage() { load(refresh: true) }
    @objc private func close() {
        cancelLoad()
        surface.suspend()
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
