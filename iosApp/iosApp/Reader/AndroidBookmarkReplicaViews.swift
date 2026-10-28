import shared
import UIKit

final class AndroidBookmarkEmptyView: UIView {
    private let iconView = UIImageView(image: UIImage(systemName: "bookmark"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(title: String, detail: String?) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail?.isEmpty != false
    }

    private func configureViews() {
        iconView.tintColor = AndroidReplicaTheme.secondaryText.withAlphaComponent(0.72)
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

final class AndroidBookmarkReplicaCell: UITableViewCell {
    static let reuseIdentifier = "AndroidBookmarkReplicaCell"

    var onMoreTap: (() -> Void)?

    private let iconView = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    private let chapterLabel = UILabel()
    private let bookTextLabel = UILabel()
    private let contentLabel = UILabel()
    private let metaLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let dividerView = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onMoreTap = nil
    }

    func configure(with bookmark: Bookmark) {
        let chapterName = bookmark.chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        chapterLabel.text = chapterName.isEmpty
            ? L10n.Reader.bookmarkChapterTitle(Int(bookmark.chapterIndex) + 1)
            : chapterName
        configureOptionalLabel(bookTextLabel, text: bookmark.bookText)
        configureOptionalLabel(contentLabel, text: bookmark.content)
        metaLabel.text = L10n.Reader.bookmarkMeta(
            chapterIndex: Int(bookmark.chapterIndex) + 1,
            position: Int(bookmark.chapterPos)
        )
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectedBackgroundView = {
            let view = UIView()
            view.backgroundColor = AndroidReplicaTheme.activeIndicator
            return view
        }()

        iconView.tintColor = AndroidReplicaTheme.accent
        iconView.contentMode = .scaleAspectFit

        chapterLabel.font = .preferredFont(forTextStyle: .body)
        chapterLabel.adjustsFontForContentSizeCategory = true
        chapterLabel.textColor = AndroidReplicaTheme.primaryText
        chapterLabel.numberOfLines = 1

        for label in [bookTextLabel, contentLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = AndroidReplicaTheme.secondaryText
            label.numberOfLines = 2
        }

        metaLabel.font = .preferredFont(forTextStyle: .caption1)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = AndroidReplicaTheme.secondaryText.withAlphaComponent(0.86)
        metaLabel.numberOfLines = 1

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.secondaryText
        moreButton.accessibilityLabel = L10n.Bookshelf.moreActions
        moreButton.addTarget(self, action: #selector(handleMoreTap), for: .touchUpInside)
        moreButton.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [chapterLabel, bookTextLabel, contentLabel, metaLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        for item in [iconView, textStack, moreButton, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        dividerView.backgroundColor = AndroidReplicaTheme.divider

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),

            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -6),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            dividerView.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    private func configureOptionalLabel(_ label: UILabel, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        label.text = trimmed
        label.isHidden = trimmed.isEmpty
    }

    @objc private func handleMoreTap() {
        onMoreTap?()
    }
}

final class AndroidBookmarkEditorSheetViewController: UIViewController {
    private let bookmark: Bookmark
    private let onSave: (String, String) -> Void
    private let onDelete: () -> Void
    private let stackView = UIStackView()
    private let bookTextView = UITextView()
    private let contentView = UITextView()

    init(bookmark: Bookmark, onSave: @escaping (String, String) -> Void, onDelete: @escaping () -> Void) {
        self.bookmark = bookmark
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
        title = L10n.AllBookmark.editBookmark
        preferredContentSize = CGSize(width: 0, height: 360)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)

        let chapterLabel = UILabel()
        let chapterName = bookmark.chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        chapterLabel.text = chapterName.isEmpty
            ? L10n.Reader.bookmarkChapterTitle(Int(bookmark.chapterIndex) + 1)
            : chapterName
        chapterLabel.font = .systemFont(ofSize: 14, weight: .medium)
        chapterLabel.textColor = AndroidReplicaTheme.secondaryText
        chapterLabel.numberOfLines = 2

        configure(textView: bookTextView, text: bookmark.bookText)
        configure(textView: contentView, text: bookmark.content)

        let actionRow = UIStackView(arrangedSubviews: [
            actionButton(title: L10n.Common.delete, color: UIColor(red: 0.82, green: 0.18, blue: 0.18, alpha: 1), action: #selector(handleDelete)),
            actionButton(title: L10n.Common.cancel, color: AndroidReplicaTheme.secondaryText, action: #selector(handleCancel)),
            actionButton(title: L10n.Common.save, color: AndroidReplicaTheme.accent, action: #selector(handleSave)),
        ])
        actionRow.axis = .horizontal
        actionRow.spacing = 10
        actionRow.distribution = .fillEqually

        for item in [chapterLabel, labeledBlock(title: L10n.AllBookmark.originalText, textView: bookTextView), labeledBlock(title: L10n.AllBookmark.summary, textView: contentView), actionRow] {
            stackView.addArrangedSubview(item)
        }

        view.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bookTextView.heightAnchor.constraint(equalToConstant: 72),
            contentView.heightAnchor.constraint(equalToConstant: 72),
            actionRow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configure(textView: UITextView, text: String) {
        textView.text = text
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 8, bottom: 9, right: 8)
    }

    private func labeledBlock(title: String, textView: UITextView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = AndroidReplicaTheme.secondaryText
        let stack = UIStackView(arrangedSubviews: [label, textView])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func actionButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.backgroundColor = AndroidReplicaTheme.menuBackground
        button.layer.cornerRadius = 8
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func handleSave() {
        dismiss(animated: true) { [onSave, bookTextView, contentView] in
            onSave(bookTextView.text ?? "", contentView.text ?? "")
        }
    }

    @objc private func handleDelete() {
        dismiss(animated: true) { [onDelete] in onDelete() }
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}

final class AndroidBookmarkDetailSheetViewController: UIViewController {
    private let titleText: String
    private let bookText: String
    private let contentText: String

    init(titleText: String, bookText: String, contentText: String) {
        self.titleText = titleText
        self.bookText = bookText
        self.contentText = contentText
        super.init(nibName: nil, bundle: nil)
        title = L10n.Reader.bookmarkViewDetail
        preferredContentSize = CGSize(width: 0, height: 390)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        let bookText = bookText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentText = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if bookText.isEmpty == false {
            stack.addArrangedSubview(labeledTextBlock(title: L10n.AllBookmark.originalText, text: bookText))
        }
        if contentText.isEmpty == false {
            stack.addArrangedSubview(labeledTextBlock(title: L10n.AllBookmark.summary, text: contentText))
        }
        if bookText.isEmpty, contentText.isEmpty {
            stack.addArrangedSubview(labeledTextBlock(title: L10n.AllBookmark.summary, text: L10n.Reader.bookmarkEmptyMessage))
        }
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func labeledTextBlock(title: String, text: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = AndroidReplicaTheme.secondaryText

        let textView = UITextView()
        textView.text = text
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.layer.cornerRadius = 8
        textView.isEditable = false
        textView.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let stack = UIStackView(arrangedSubviews: [label, textView])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }
}
