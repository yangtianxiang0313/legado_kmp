import UIKit

@MainActor
final class AudioPlaybackBar: UIView {
    private let titleButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    var onOpen: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var visible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = AndroidReplicaTheme.bottomBackground
        accessibilityIdentifier = "audioPlay.miniPlayer"
        titleButton.contentHorizontalAlignment = .leading
        titleButton.titleLabel?.numberOfLines = 2
        titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        titleButton.titleLabel?.font = .systemFont(ofSize: 13)
        titleButton.accessibilityIdentifier = "audioPlay.reopen"
        titleButton.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        playButton.accessibilityIdentifier = "audioPlay.miniToggle"
        playButton.addAction(UIAction { _ in AudioPlaybackSession.shared.togglePlayback() }, for: .touchUpInside)
        stopButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopButton.accessibilityIdentifier = "audioPlay.miniStop"
        stopButton.accessibilityLabel = "停止有声播放"
        stopButton.addAction(UIAction { _ in AudioPlaybackSession.shared.stop() }, for: .touchUpInside)
        for button in [titleButton, playButton, stopButton] {
            button.tintColor = AndroidReplicaTheme.primaryText
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            button.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        NSLayoutConstraint.activate([
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            playButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 48),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stopButton.widthAnchor.constraint(equalToConstant: 48),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: AudioPlaybackSession.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: .androidReplicaThemeDidChange, object: nil)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func render() {
        let session = AudioPlaybackSession.shared
        let nextVisible = session.bookURL != nil
        isHidden = !nextVisible
        if visible != nextVisible {
            visible = nextVisible
            onVisibilityChange?(visible)
        }
        backgroundColor = AndroidReplicaTheme.bottomBackground
        for button in [titleButton, playButton, stopButton] { button.tintColor = AndroidReplicaTheme.primaryText }
        titleButton.setTitle(
            [session.book?.name ?? "正在加载", session.chapterTitle.nilIfEmpty].compactMap { $0 }.joined(separator: "\n"),
            for: .normal)
        let playing = session.player.state == .playing
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = playing ? "暂停有声播放" : "继续有声播放"
        titleButton.accessibilityLabel = session.errorMessage ?? "返回播放器，\(session.book?.name ?? "正在加载")，\(session.chapterTitle)"
    }
}
