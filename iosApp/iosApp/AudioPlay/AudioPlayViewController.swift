import UIKit
import shared

final class AudioPlayViewController: UIViewController, NavigationContentChromeProviding {

    // MARK: - Properties

    private let bookUrl: String
    private let initialChapterIndex: Int?
    private let initialChapterPosition: Int?
    private let session = AudioPlaybackSession.shared
    private var coverTask: Task<Void, Never>?
    private var displayedCover: String?
    private var displayedError: String?
    private var isClosing = false
    private lazy var chapterListCoordinator: AudioChapterListPresentationCoordinator = AudioChapterListPresentationCoordinator(
        session: session,
        canPresent: { [weak self] in
            guard let self else { return false }
            return !self.isClosing && !self.recoveryActions.isBusy
        })
    private lazy var recoveryActions: AudioPlayRecoveryActions = AudioPlayRecoveryActions(
        presenter: self, bookURL: bookUrl, session: session,
        onLeaving: { [weak self] in
            self?.isClosing = true
            self?.coverTask?.cancel()
            self?.chapterListCoordinator.cancel()
        })
    private let changeSourceButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    // MARK: - UI Elements

    private let backgroundImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let backgroundOverlay: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 100
        iv.layer.borderWidth = 2
        iv.layer.borderColor = UIColor.systemBlue.cgColor
        iv.backgroundColor = .systemGray5
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let chapterTitleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeCurrentLabel: UILabel = {
        let label = UILabel()
        label.text = "00:00"
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeTotalLabel: UILabel = {
        let label = UILabel()
        label.text = "00:00"
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressSlider: UISlider = {
        let slider = UISlider()
        slider.minimumTrackTintColor = .systemBlue
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.value = 0
        return slider
    }()

    private let playButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        button.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let prevButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        button.setImage(UIImage(systemName: "backward.end.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let nextButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        button.setImage(UIImage(systemName: "forward.end.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let speedDownButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        button.setImage(UIImage(systemName: "gobackward", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let speedUpButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        button.setImage(UIImage(systemName: "goforward", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let timerButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        button.setImage(UIImage(systemName: "timer", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let chapterListButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        button.setImage(UIImage(systemName: "list.bullet", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let speedLabel: UILabel = {
        let label = UILabel()
        label.text = "1.0X"
        label.textColor = .white.withAlphaComponent(0.8)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timerLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white.withAlphaComponent(0.8)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .left
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let playModeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        button.setImage(UIImage(systemName: "list.number", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private var isSeeking = false

    // MARK: - Init

    init(bookUrl: String, initialChapterIndex: Int? = nil, initialChapterPosition: Int? = nil) {
        self.bookUrl = bookUrl
        self.initialChapterIndex = initialChapterIndex
        self.initialChapterPosition = initialChapterPosition
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        coverTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupActions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(renderSession), name: AudioPlaybackSession.didChange, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeRecoveryNavigation), name: UIApplication.didBecomeActiveNotification, object: nil)
        session.open(bookURL: bookUrl, chapterIndex: initialChapterIndex, position: initialChapterPosition)
        renderSession()
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        renderSession()
        recoveryActions.navigateIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let isLeaving = isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true
        if isLeaving || !(presentedViewController is AndroidChapterListSheetViewController) {
            chapterListCoordinator.cancel()
        }
        if isLeaving {
            recoveryActions.cancelPreparation()
            session.saveProgress()
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.accessibilityIdentifier = "audioPlay.screen"
        view.addSubview(backgroundImageView)
        view.addSubview(backgroundOverlay)
        view.addSubview(coverImageView)
        view.addSubview(chapterTitleLabel)
        view.addSubview(timerLabel)
        view.addSubview(speedLabel)
        view.addSubview(playModeButton)

        let progressStack = UIStackView(arrangedSubviews: [timeCurrentLabel, progressSlider, timeTotalLabel])
        progressStack.axis = .horizontal
        progressStack.spacing = 8
        progressStack.alignment = .center
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressStack)

        let controlStack = UIStackView(arrangedSubviews: [
            timerButton, speedDownButton, prevButton, playButton, nextButton, speedUpButton, chapterListButton,
        ])
        controlStack.axis = .horizontal
        controlStack.distribution = .equalSpacing
        controlStack.alignment = .center
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlStack)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityIdentifier = "audioPlay.close"
        closeButton.accessibilityLabel = L10n.Common.close
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        changeSourceButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath"), for: .normal)
        changeSourceButton.accessibilityIdentifier = "audioPlay.changeSource"
        changeSourceButton.accessibilityLabel = "换源"
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.accessibilityIdentifier = "audioPlay.more"
        moreButton.accessibilityLabel = "更多"
        for button in [changeSourceButton, moreButton] {
            button.tintColor = .white
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
        }

        NSLayoutConstraint.activate([
            backgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            backgroundOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            moreButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            moreButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            changeSourceButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            changeSourceButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            changeSourceButton.widthAnchor.constraint(equalToConstant: 44),
            changeSourceButton.heightAnchor.constraint(equalToConstant: 44),

            timerLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            timerLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            timerLabel.trailingAnchor.constraint(lessThanOrEqualTo: speedLabel.leadingAnchor, constant: -8),

            speedLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            speedLabel.trailingAnchor.constraint(equalTo: changeSourceButton.leadingAnchor, constant: -8),

            coverImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            coverImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            coverImageView.widthAnchor.constraint(equalToConstant: 200),
            coverImageView.heightAnchor.constraint(equalToConstant: 200),

            playModeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playModeButton.topAnchor.constraint(equalTo: coverImageView.bottomAnchor, constant: 16),

            chapterTitleLabel.topAnchor.constraint(equalTo: playModeButton.bottomAnchor, constant: 8),
            chapterTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            chapterTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            progressStack.topAnchor.constraint(equalTo: chapterTitleLabel.bottomAnchor, constant: 24),
            progressStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            controlStack.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 24),
            controlStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            controlStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func setupActions() {
        playButton.accessibilityIdentifier = "audioPlay.toggle"
        prevButton.accessibilityIdentifier = "audioPlay.previous"
        prevButton.accessibilityLabel = "上一章"
        nextButton.accessibilityIdentifier = "audioPlay.next"
        nextButton.accessibilityLabel = "下一章"
        chapterListButton.accessibilityIdentifier = "audioPlay.catalog"
        chapterListButton.accessibilityLabel = "目录"
        timerButton.accessibilityLabel = "定时停止"
        progressSlider.accessibilityIdentifier = "audioPlay.position"
        changeSourceButton.addTarget(self, action: #selector(changeSourceTapped), for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosing else { completion([]); return }
                    self.chapterListCoordinator.cancel()
                    let items = await self.recoveryActions.menuElements()
                    completion(items)
                }
            }
        ])
        playButton.menu = UIMenu(children: [
            UIAction(title: "停止播放", image: UIImage(systemName: "stop.fill")) { [weak self] _ in
                self?.session.stop()
                self?.closeTapped()
            }
        ])
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        speedDownButton.addTarget(self, action: #selector(speedDownTapped), for: .touchUpInside)
        speedUpButton.addTarget(self, action: #selector(speedUpTapped), for: .touchUpInside)
        timerButton.addTarget(self, action: #selector(timerTapped), for: .touchUpInside)
        chapterListButton.addTarget(self, action: #selector(chapterListTapped), for: .touchUpInside)
        playModeButton.addTarget(self, action: #selector(playModeTapped), for: .touchUpInside)

        progressSlider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func renderSession() {
        guard !isClosing, session.bookURL == bookUrl else {
            chapterListCoordinator.cancel()
            return
        }
        title = session.book?.name
        chapterTitleLabel.text = session.chapterTitle
        prevButton.isEnabled = !session.isChangingSource && session.currentChapterIndex > 0
        nextButton.isEnabled =
            !session.isChangingSource
            && (session.currentChapterIndex < session.totalChapters - 1 || session.playMode != .listEndStop)
        playButton.isEnabled = !session.isChangingSource
        changeSourceButton.isEnabled = session.book?.isLocal == false && !session.isChangingSource
        moreButton.isEnabled = !session.isChangingSource
        speedLabel.text = String(format: "%.1fX", session.player.speed)
        timerLabel.isHidden = session.timerMinutes == 0
        timerLabel.text = "\(session.timerMinutes)m"
        playModeButton.accessibilityLabel = session.playMode.title
        updatePlayButtonIcon()
        updatePlayModeIcon()
        if !isSeeking {
            timeCurrentLabel.text = formatTime(session.currentTime)
            timeTotalLabel.text = formatTime(session.duration)
            progressSlider.value = session.duration > 0 ? Float(session.currentTime / session.duration) : 0
        }
        progressSlider.isEnabled = session.canSeek && session.duration > 0
        if let book = session.book, displayedCover != book.bookUrl + "|" + (book.displayCoverUrl ?? "") {
            displayedCover = book.bookUrl + "|" + (book.displayCoverUrl ?? "")
            coverTask?.cancel()
            coverTask = Task { [weak self] in
                let image = await BookCoverImageLoader.loadDecodedCover(book: book)
                guard !Task.isCancelled, let self, !isClosing else { return }
                let cover =
                    image
                    ?? AndroidDefaultBookCoverRenderer.image(
                        name: book.name, author: book.author, size: CGSize(width: 200, height: 200))
                coverImageView.image = cover
                backgroundImageView.image = cover
            }
        }
        if let error = session.errorMessage, error != displayedError, view.window != nil {
            displayedError = error
            showTransientMessage(error)
        }
        if session.errorMessage == nil { displayedError = nil }
    }

    // MARK: - Actions

    @objc private func changeSourceTapped() {
        chapterListCoordinator.cancel()
        recoveryActions.presentSourcePicker()
    }

    @objc private func resumeRecoveryNavigation() {
        guard !isClosing else { return }
        recoveryActions.navigateIfNeeded()
    }

    @objc private func playTapped() {
        session.togglePlayback()
    }

    @objc private func prevTapped() {
        session.previous()
    }

    @objc private func nextTapped() {
        session.next()
    }

    @objc private func speedDownTapped() {
        session.adjustSpeed(by: -0.1)
    }

    @objc private func speedUpTapped() {
        session.adjustSpeed(by: 0.1)
    }

    @objc private func timerTapped() {
        chapterListCoordinator.cancel()
        let alert = UIAlertController(title: L10n.AudioPlay.timerTitle, message: nil, preferredStyle: .actionSheet)
        for minutes in [0, 10, 20, 30, 60, 90, 120, 180] {
            let title =
                minutes == 0
                ? L10n.AudioPlay.timerOff
                : L10n.AudioPlay.timerMinutes(minutes)
            alert.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.session.setTimer(minutes: minutes)
                })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = timerButton
            popover.sourceRect = timerButton.bounds
        }
        present(alert, animated: true)
    }

    @objc private func chapterListTapped() {
        chapterListCoordinator.present(in: self, bookURL: bookUrl)
    }

    @objc private func playModeTapped() {
        session.cycleMode()
    }

    @objc private func closeTapped() {
        guard !recoveryActions.isBusy else { return }
        session.saveProgress()
        isClosing = true
        coverTask?.cancel()
        chapterListCoordinator.cancel()
        ChapterListNavigation.close(self, completion: {})
    }

    // MARK: - Slider

    @objc private func sliderBegan() { isSeeking = true }

    @objc private func sliderChanged() {
        let time = TimeInterval(progressSlider.value) * session.duration
        timeCurrentLabel.text = formatTime(time)
    }

    @objc private func sliderEnded() {
        let time = TimeInterval(progressSlider.value) * session.duration
        session.seek(to: time)
        isSeeking = false
    }

    // MARK: - UI Updates

    private func updatePlayButtonIcon() {
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let name: String
        switch session.player.state {
        case .playing: name = "pause.circle.fill"
        case .paused, .stopped: name = "play.circle.fill"
        case .loading: name = "circle.dashed"
        }
        playButton.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        playButton.accessibilityLabel = session.player.state == .playing ? "暂停" : "播放"
    }

    private func updatePlayModeIcon() {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        playModeButton.setImage(UIImage(systemName: session.playMode.iconName, withConfiguration: config), for: .normal)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = time.isFinite ? Int(min(max(0, time), 100_000_000)) : 0
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

}
