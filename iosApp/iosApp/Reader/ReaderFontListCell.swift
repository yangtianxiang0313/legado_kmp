import UIKit

final class ReaderFontListCell: UITableViewCell {
    static let reuseIdentifier = "ReaderFontListCell"
    private(set) var representedEntry: ReaderFontEntry?

    private let filenameLabel = UILabel()
    private let checkImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        isAccessibilityElement = true
        filenameLabel.numberOfLines = 0
        filenameLabel.lineBreakMode = .byCharWrapping
        filenameLabel.textAlignment = .natural
        filenameLabel.adjustsFontSizeToFitWidth = false
        filenameLabel.isAccessibilityElement = false
        checkImageView.image = UIImage(named: "ReaderTocAndroidCheck")?.withRenderingMode(.alwaysTemplate)
        checkImageView.contentMode = .scaleAspectFit
        checkImageView.isAccessibilityElement = false

        let highlightView = UIView()
        highlightView.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = highlightView

        contentView.addSubview(filenameLabel)
        contentView.addSubview(checkImageView)
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        checkImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // item_font: 24dp check plus the root's 5dp vertical padding.
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            filenameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            filenameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            filenameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            filenameLabel.trailingAnchor.constraint(equalTo: checkImageView.leadingAnchor, constant: -5),
            checkImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            checkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkImageView.widthAnchor.constraint(equalToConstant: 24),
            checkImageView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedEntry = nil
        filenameLabel.text = nil
        checkImageView.alpha = 0
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityTraits = .button
    }

    func configure(entry: ReaderFontEntry, font: UIFont, textColor: UIColor, selected: Bool, enabled: Bool) {
        representedEntry = entry
        filenameLabel.text = entry.title
        filenameLabel.font = font
        filenameLabel.textColor = textColor
        checkImageView.tintColor = textColor
        // Keep the 24pt check slot even for unselected rows.
        checkImageView.alpha = selected ? 1 : 0
        accessibilityIdentifier = "reader.font.item.\(entry.identifier)"
        accessibilityLabel = entry.title
        accessibilityTraits = selected ? [.button, .selected] : .button
        setInteractionEnabled(enabled)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        isUserInteractionEnabled = enabled
        selectionStyle = enabled ? .default : .none
        if enabled {
            accessibilityTraits.remove(.notEnabled)
        } else {
            accessibilityTraits.insert(.notEnabled)
        }
    }
}
