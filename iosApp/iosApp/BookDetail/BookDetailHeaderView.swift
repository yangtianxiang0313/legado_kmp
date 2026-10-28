import UIKit
import shared
import Kingfisher
import SnapKit
import Then

final class BookDetailHeaderView: UIView {
    private enum Metrics {
        static let backgroundHeight: CGFloat = 248
        static let heroTopInset: CGFloat = 14
        static let coverWidth: CGFloat = 118
        static let coverHeight: CGFloat = 172
        static let arcHeight: CGFloat = 78
        static let arcCurveHeight: CGFloat = 36
        static let contentHorizontalInset: CGFloat = 20
        static let contentVerticalInset: CGFloat = 24
    }

    private let placeholderImage = UIImage(systemName: "book.closed")
    private let accessibilityMarker = UIView().then {
        $0.isAccessibilityElement = true
        $0.accessibilityIdentifier = UIIdentifiers.BookDetail.header
        $0.backgroundColor = .clear
        $0.alpha = 0.01
    }

    private let backgroundImageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.alpha = 0.3
        $0.backgroundColor = .secondarySystemBackground
    }

    private let backgroundOverlayView = UIView().then {
        $0.backgroundColor = UIColor.black.withAlphaComponent(0.22)
    }

    private let heroContainerView = UIView()
    private let arcBackgroundView = BookDetailArcView()

    private let coverCardView = UIView().then {
        $0.backgroundColor = .systemBackground
        $0.layer.cornerRadius = 5
        $0.layer.cornerCurve = .continuous
        $0.layer.shadowColor = UIColor.black.cgColor
        $0.layer.shadowOpacity = 0.18
        $0.layer.shadowRadius = 10
        $0.layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    private let coverImageView = UIImageView().then {
        $0.contentMode = .scaleAspectFill
        $0.clipsToBounds = true
        $0.backgroundColor = .secondarySystemBackground
        $0.tintColor = .tertiaryLabel
    }

    private let infoContainerView = UIView().then {
        $0.backgroundColor = .systemBackground
    }

    private let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = AppUI.Spacing.large
    }

    private let titleActionView = BookDetailHeaderTextActionView(
        font: .preferredFont(forTextStyle: .title3),
        textColor: .label,
        accessibilityIdentifier: UIIdentifiers.BookDetail.headerTitleAction
    )

    private let kindsLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption1)
        $0.textColor = .systemOrange
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.isHidden = true
    }

    private let fileSizeLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .caption1)
        $0.textColor = .tertiaryLabel
        $0.textAlignment = .center
        $0.isHidden = true
    }

    private let authorActionView = BookDetailHeaderTextActionView(
        font: .preferredFont(forTextStyle: .subheadline),
        textColor: .secondaryLabel,
        accessibilityIdentifier: UIIdentifiers.BookDetail.headerAuthorAction
    )

    private let infoStackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = AppUI.Spacing.small
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
        $0.setContentHuggingPriority(.required, for: .vertical)
    }

    private let sourceRow = BookDetailInfoRowView(
        iconName: "globe",
        accessibilityIdentifier: UIIdentifiers.BookDetail.infoSourceRow,
        actionAccessibilityIdentifier: UIIdentifiers.BookDetail.infoSourceAction
    )

    private let progressRow = BookDetailInfoRowView(
        iconName: "bookmark",
        accessibilityIdentifier: UIIdentifiers.BookDetail.infoProgressRow
    )

    private let groupRow = BookDetailInfoRowView(
        iconName: "folder",
        accessibilityIdentifier: UIIdentifiers.BookDetail.infoGroupRow,
        actionAccessibilityIdentifier: UIIdentifiers.BookDetail.infoGroupAction
    )

    private let latestChapterRow = BookDetailInfoRowView(
        iconName: "arrow.up.circle",
        accessibilityIdentifier: "bookDetail.info.latestChapter"
    )

    private let tocRow = BookDetailInfoRowView(
        iconName: "list.bullet",
        accessibilityIdentifier: UIIdentifiers.BookDetail.infoTocRow,
        actionAccessibilityIdentifier: UIIdentifiers.BookDetail.infoTocAction
    )

    private let introLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 4
        $0.lineBreakMode = .byWordWrapping
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
        $0.setContentHuggingPriority(.required, for: .vertical)
    }

    private let introExpandButton = UIButton(type: .system).then {
        $0.setTitle(L10n.BookDetail.expandIntro, for: .normal)
        $0.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        $0.isHidden = true
    }

    private var isIntroExpanded = false

    private var coverTask: Task<Void, Never>?
    private var coverLoadKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = false

        titleActionView.onTap = { [weak self] in
            self?.onTitleTap?()
        }
        authorActionView.onTap = { [weak self] in
            self?.onAuthorTap?()
        }
        sourceRow.onActionTap = { [weak self] in
            self?.onChangeSourceTap?()
        }
        groupRow.onActionTap = { [weak self] in
            self?.onChangeGroupTap?()
        }
        tocRow.onActionTap = { [weak self] in
            self?.onChapterListTap?()
        }

        addSubview(backgroundImageView)
        addSubview(backgroundOverlayView)
        addSubview(accessibilityMarker)
        addSubview(heroContainerView)
        addSubview(infoContainerView)

        heroContainerView.addSubview(arcBackgroundView)
        heroContainerView.addSubview(coverCardView)
        coverCardView.addSubview(coverImageView)

        infoContainerView.addSubview(stackView)
        [sourceRow, progressRow, latestChapterRow, groupRow, tocRow].forEach(infoStackView.addArrangedSubview)
        [titleActionView, kindsLabel, fileSizeLabel, authorActionView, infoStackView, introLabel, introExpandButton].forEach(stackView.addArrangedSubview)

        introExpandButton.addTarget(self, action: #selector(handleIntroExpandToggle), for: .touchUpInside)

        let coverTap = UITapGestureRecognizer(target: self, action: #selector(handleCoverTap))
        coverCardView.addGestureRecognizer(coverTap)
        let coverLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCoverLongPress(_:)))
        coverCardView.addGestureRecognizer(coverLongPress)
        coverCardView.isUserInteractionEnabled = true

        accessibilityMarker.translatesAutoresizingMaskIntoConstraints = false

        backgroundImageView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Metrics.backgroundHeight)
        }

        backgroundOverlayView.snp.makeConstraints { make in
            make.edges.equalTo(backgroundImageView)
        }

        heroContainerView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.heroTopInset)
            make.leading.trailing.equalToSuperview()
        }

        arcBackgroundView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(Metrics.arcHeight)
        }

        coverCardView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.equalTo(Metrics.coverWidth)
            make.height.equalTo(Metrics.coverHeight)
            make.bottom.equalToSuperview().offset(-24)
        }

        coverImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(3)
        }

        infoContainerView.snp.makeConstraints { make in
            make.top.equalTo(heroContainerView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        stackView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.contentVerticalInset)
            make.leading.trailing.equalToSuperview().inset(Metrics.contentHorizontalInset)
            make.bottom.equalToSuperview().offset(-Metrics.contentVerticalInset)
        }

        titleActionView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(30)
        }

        authorActionView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(24)
        }

        [titleActionView, authorActionView, sourceRow, progressRow, latestChapterRow, groupRow, tocRow].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
            $0.setContentHuggingPriority(.required, for: .vertical)
        }

        stackView.setCustomSpacing(AppUI.Spacing.small, after: titleActionView)
        stackView.setCustomSpacing(AppUI.Spacing.medium, after: authorActionView)
        stackView.setCustomSpacing(AppUI.Spacing.large, after: infoStackView)

        NSLayoutConstraint.activate([
            accessibilityMarker.leadingAnchor.constraint(equalTo: leadingAnchor),
            accessibilityMarker.topAnchor.constraint(equalTo: topAnchor),
            accessibilityMarker.widthAnchor.constraint(equalToConstant: 1),
            accessibilityMarker.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var onTitleTap: (() -> Void)?
    var onAuthorTap: (() -> Void)?
    var onChapterListTap: (() -> Void)?
    var onChangeSourceTap: (() -> Void)?
    var onChangeGroupTap: (() -> Void)?
    var onCoverTap: (() -> Void)?
    var onCoverLongPress: ((UIImage?) -> Void)?

    func configure(
        book: Book?,
        chapterCount: Int,
        isInBookshelf: Bool,
        readingHint: String,
        chapterHint: String,
        groupName: String,
        latestChapter: String? = nil
    ) {
        let titleText = book.map { $0.name.sanitizedDisplayText }.flatMap { $0.nilIfEmpty } ?? L10n.BookDetail.title
        titleActionView.setText(titleText)

        let authorText = book
            .map { $0.author.sanitizedDisplayText }
            .flatMap { $0.nilIfEmpty } ?? L10n.BookDetail.unknownAuthor
        authorActionView.setText(authorText)
        authorActionView.isHidden = authorText == L10n.BookDetail.unknownAuthor

        let kindText = book?.kind?.sanitizedDisplayText.nilIfEmpty
            ?? book?.customTag?.sanitizedDisplayText.nilIfEmpty
        kindsLabel.text = kindText
        kindsLabel.isHidden = kindText == nil

        if let book, book.isLocal {
            let path = book.bookUrl
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64, size > 0 {
                fileSizeLabel.text = String(format: L10n.BookDetail.fileSizeFormat, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                fileSizeLabel.isHidden = false
            } else {
                fileSizeLabel.isHidden = true
            }
        } else {
            fileSizeLabel.isHidden = true
        }

        sourceRow.configure(
            text: String(
                format: L10n.BookDetail.sourceFormat,
                book.map { $0.originName.sanitizedDisplayText }.flatMap { $0.nilIfEmpty } ?? L10n.BookDetail.unknownSource
            ),
            actionTitle: L10n.BookDetail.changeSource
        )
        progressRow.configure(
            text: String(format: L10n.BookDetail.progressFormat, readingHint),
            actionTitle: nil
        )
        groupRow.configure(
            text: String(format: L10n.BookDetail.groupFormat, groupName),
            actionTitle: L10n.BookDetail.changeGroup
        )
        tocRow.configure(
            text: String(format: L10n.BookDetail.tocFormat, chapterHint),
            actionTitle: L10n.BookDetail.viewToc
        )

        let latestText = latestChapter ?? book?.latestChapterTitle?.sanitizedDisplayText.nilIfEmpty
        if let latestText {
            latestChapterRow.configure(
                text: String(format: L10n.BookDetail.latestChapterFormat, latestText),
                actionTitle: nil
            )
            latestChapterRow.isHidden = false
        } else {
            latestChapterRow.isHidden = true
        }

        let introText = book?.displayIntro?.sanitizedDisplayText.nilIfEmpty ?? L10n.BookDetail.emptyIntro
        introLabel.text = introText
        updateIntroExpandButton()

        let resolvedChapterCount = max(chapterCount, Int(book?.totalChapterNum ?? 0))
        accessibilityMarker.accessibilityValue = [
            titleText,
            authorActionView.isHidden ? nil : authorText,
            kindText,
            sourceRow.accessibilityValue,
            progressRow.accessibilityValue,
            groupRow.accessibilityValue,
            tocRow.accessibilityValue,
            resolvedChapterCount > 0 ? String(format: L10n.BookDetail.totalChapters, resolvedChapterCount) : nil,
            introLabel.text,
            isInBookshelf ? L10n.BookDetail.shelfStatusIn : L10n.BookDetail.shelfStatusOut,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        coverTask?.cancel()
        coverTask = nil
        coverLoadKey = nil
        coverImageView.kf.cancelDownloadTask()
        backgroundImageView.kf.cancelDownloadTask()

        guard let book, let cover = book.displayCoverUrl, let url = URL(string: cover) else {
            coverImageView.image = placeholderImage
            backgroundImageView.image = placeholderImage
            return
        }
        let requestKey = BookCoverImageLoader.coverCacheKey(for: book) as String
        coverLoadKey = requestKey
        coverImageView.image = placeholderImage
        backgroundImageView.image = placeholderImage
        coverTask = Task { [weak self] in
            guard let self else { return }
            if let decoded = await BookCoverImageLoader.loadDecodedCover(book: book) {
                await MainActor.run {
                    guard self.coverLoadKey == requestKey else { return }
                    self.coverImageView.image = decoded
                    self.backgroundImageView.image = decoded
                }
                return
            }
            await MainActor.run {
                guard self.coverLoadKey == requestKey else { return }
                self.coverImageView.kf.setImage(
                    with: url,
                    placeholder: self.placeholderImage,
                    options: [
                        .transition(.fade(0.2)),
                        .cacheOriginalImage,
                    ]
                )
                self.backgroundImageView.kf.setImage(
                    with: url,
                    placeholder: self.placeholderImage,
                    options: [
                        .transition(.fade(0.2)),
                        .cacheOriginalImage,
                    ]
                )
            }
        }
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        return systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func updateIntroExpandButton() {
        let text = introLabel.text ?? ""
        if text == L10n.BookDetail.emptyIntro || text.isEmpty {
            introExpandButton.isHidden = true
            return
        }
        introLabel.layoutIfNeeded()
        let maxSize = CGSize(width: introLabel.bounds.width > 0 ? introLabel.bounds.width : UIScreen.main.bounds.width - 40, height: .greatestFiniteMagnitude)
        let fullHeight = ((introLabel.text ?? "") as NSString).boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: introLabel.font as Any],
            context: nil
        ).height
        let lineHeight = introLabel.font.lineHeight
        let needsExpand = fullHeight > lineHeight * 4.5
        introExpandButton.isHidden = !needsExpand
        introExpandButton.setTitle(isIntroExpanded ? L10n.BookDetail.collapseIntro : L10n.BookDetail.expandIntro, for: .normal)
    }

    @objc private func handleIntroExpandToggle() {
        isIntroExpanded.toggle()
        introLabel.numberOfLines = isIntroExpanded ? 0 : 4
        introExpandButton.setTitle(isIntroExpanded ? L10n.BookDetail.collapseIntro : L10n.BookDetail.expandIntro, for: .normal)
    }

    @objc private func handleCoverTap() {
        onCoverTap?()
    }

    @objc private func handleCoverLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onCoverLongPress?(coverImageView.image)
    }
}

private final class BookDetailHeaderTextActionView: UIControl {
    private let label = UILabel()
    var onTap: (() -> Void)?

    init(font: UIFont, textColor: UIColor, accessibilityIdentifier: String) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityTraits = [.button]

        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = textColor
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false

        addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.text = text
        accessibilityLabel = text
        accessibilityValue = text
    }

    @objc private func handleTap() {
        onTap?()
    }
}

private final class BookDetailInfoRowView: UIView {
    private let iconView = UIImageView()
    private let textLabel = UILabel()
    private let actionButton: UIButton?
    private let stackView = UIStackView()

    var onActionTap: (() -> Void)?

    init(iconName: String, accessibilityIdentifier: String, actionAccessibilityIdentifier: String? = nil) {
        if let actionAccessibilityIdentifier {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
            button.configuration = configuration
            button.accessibilityIdentifier = actionAccessibilityIdentifier
            self.actionButton = button
        } else {
            self.actionButton = nil
        }
        super.init(frame: .zero)

        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = false

        iconView.image = UIImage(systemName: iconName)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        textLabel.font = .preferredFont(forTextStyle: .subheadline)
        textLabel.textColor = .secondaryLabel
        textLabel.numberOfLines = 1
        textLabel.isAccessibilityElement = true
        textLabel.accessibilityIdentifier = accessibilityIdentifier
        textLabel.accessibilityTraits = .staticText

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = AppUI.Spacing.small

        addSubview(stackView)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(textLabel)

        if let actionButton {
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stackView.addArrangedSubview(spacer)
            stackView.addArrangedSubview(actionButton)
            actionButton.addTarget(self, action: #selector(handleActionTap), for: .touchUpInside)
        }

        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(18)
        }

        actionButton?.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)

        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, actionTitle: String?) {
        textLabel.text = text
        textLabel.accessibilityLabel = text
        textLabel.accessibilityValue = text
        accessibilityValue = text
        if let actionTitle, let actionButton {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton?.isHidden = true
        }
    }

    @objc private func handleActionTap() {
        onActionTap?()
    }
}

private final class BookDetailArcView: UIView {
    private let curveHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard rect.isEmpty == false else { return }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: curveHeight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: curveHeight),
            controlPoint: CGPoint(x: rect.midX, y: -curveHeight)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        UIColor.systemBackground.setFill()
        path.fill()
    }
}
