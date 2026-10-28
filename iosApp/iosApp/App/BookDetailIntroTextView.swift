import UIKit

final class BookDetailIntroTextView: UITextView {
    override var bounds: CGRect {
        didSet {
            if bounds.width != oldValue.width {
                // Invalidate before TextKit lays out at the new width during a column transition.
                invalidateIntrinsicContentSize()
            }
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        dataDetectorTypes = []
        allowsEditingTextAttributes = false
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no

        // The containing detail scroll view owns scrolling; keep native selection gestures.
        isScrollEnabled = false
        scrollsToTop = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        contentInset = .zero
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        self.textContainer.maximumNumberOfLines = 0
        self.textContainer.lineBreakMode = .byWordWrapping
        self.textContainer.widthTracksTextView = true
        self.textContainer.heightTracksTextView = false

        textColor = AndroidReplicaTheme.secondaryText
        tintColor = AndroidReplicaTheme.accent
        textAlignment = .natural
        adjustsFontForContentSizeCategory = false
        accessibilityIdentifier = "bookDetail.intro"
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        refreshTypography()
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func render(_ displayIntro: String?) {
        // BookInfoActivity assigns getDisplayIntro() directly. Do not perform a second
        // HTML decode or collapse paragraphs in this display-text layer.
        let displayText = displayIntro?.nilIfEmpty ?? L10n.BookDetail.emptyIntro
        guard text != displayText else { return }
        text = displayText
        invalidateIntrinsicContentSize()
    }

    func refreshTypography(compatibleWith traits: UITraitCollection? = nil) {
        let nextFont = AndroidReplicaBookDetailTypography.font(
            size: 14, compatibleWith: traits ?? traitCollection)
        if font != nextFont {
            font = nextFont
        }
        textContainerInset = AndroidExploreTextMetrics.padding(
            font: nextFont, scale: (traits ?? traitCollection).displayScale)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let minimumHeight = ceil((font?.lineHeight ?? 0) + textContainerInset.top + textContainerInset.bottom)
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: minimumHeight)
        }
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(minimumHeight, ceil(fitting.height)))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.legibilityWeight != traitCollection.legibilityWeight
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            refreshTypography()
        }
    }
}
