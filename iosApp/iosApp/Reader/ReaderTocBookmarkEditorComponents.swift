import UIKit

final class ReaderTocBookmarkEditorField: UIView {
    let textView: UITextView = ReaderTocBookmarkGrowingTextView()
    private let hintLabel = UILabel()
    private let placeholderLabel = AndroidExploreTextLabel()
    private let underline = UIView()
    private var inputTop: NSLayoutConstraint!
    private var hintBaseline: NSLayoutConstraint!
    private var placeholderTop: NSLayoutConstraint!
    private var underlineHeight: NSLayoutConstraint!
    private var palette: ReaderTocPalette?
    private var pendingFontTraits: UITraitCollection?

    init(hint: String) {
        super.init(frame: .zero)
        hintLabel.text = hint
        placeholderLabel.text = hint
        textView.accessibilityLabel = hint
        for label in [hintLabel, placeholderLabel] {
            label.isAccessibilityElement = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        // AppCompat's 10/7dp drawable insets plus the nine-patch's 4dp bottom content padding.
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 11, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        placeholderLabel.isUserInteractionEnabled = false
        underline.isUserInteractionEnabled = false
        for item in [hintLabel, textView, placeholderLabel, underline] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        inputTop = textView.topAnchor.constraint(equalTo: topAnchor, constant: 15)
        hintBaseline = hintLabel.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 15)
        placeholderTop = placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10)
        underlineHeight = underline.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            hintBaseline,
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            inputTop,
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderTop,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -4),
            // Both nine-patches start their stroke 9dp above the bottom; focus grows it downward.
            underline.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: -9),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            underlineHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(hint:)")
    }

    func setText(_ text: String) {
        textView.text = text
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.invalidateIntrinsicContentSize()
        updateHint()
    }

    func applyFonts(traits: UITraitCollection) {
        // UIFont changes can replace an IME-owned draft. Apply after composition without rewriting text.
        guard textView.markedTextRange == nil else {
            pendingFontTraits = traits
            return
        }
        pendingFontTraits = nil
        let selection = textView.selectedRange
        let inputFont = ReaderAndroidDefaultFont.scaledFont(size: 18, textStyle: .body, compatibleWith: traits)
        if textView.font != inputFont { textView.font = inputFont }
        hintLabel.font = ReaderAndroidDefaultFont.scaledFont(size: 12, textStyle: .caption1, compatibleWith: traits)
        placeholderLabel.font = textView.font
        let scale = max(1, traits.displayScale)
        // BOX_BACKGROUND_NONE reserves the collapsed ascent, even while the hint is expanded.
        let hintAscent = hintLabel.font.ascender
        inputTop.constant = 3 + floor(hintAscent * scale) / scale
        hintBaseline.constant = 3 + hintAscent
        if let font = textView.font {
            let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
            textView.textContainerInset = UIEdgeInsets(
                top: 10 + padding.top, left: 4, bottom: 11 + padding.bottom, right: 4)
            // The placeholder's own line box supplies includeFontPadding exactly once, like the input.
            placeholderTop.constant = 10
        }
        if textView.selectedRange != selection { textView.selectedRange = selection }
        textView.invalidateIntrinsicContentSize()
    }

    func apply(palette: ReaderTocPalette) {
        self.palette = palette
        textView.textColor = palette.primaryText
        textView.tintColor = palette.accent
        hintLabel.textColor = palette.accent
        placeholderLabel.textColor = palette.accent
        updateUnderlineAppearance()
    }

    func updateHint() {
        if let pendingFontTraits, textView.markedTextRange == nil {
            applyFonts(traits: pendingFontTraits)
        }
        let floats = textView.isFirstResponder || !(textView.text ?? "").isEmpty
        // Hint visibility never changes the reserved input margin or the draft's layout.
        hintLabel.alpha = floats ? 1 : 0
        placeholderLabel.isHidden = floats
        updateUnderlineAppearance()
    }

    private func updateUnderlineAppearance() {
        let focused = textView.isEditable && textView.isFirstResponder
        underlineHeight.constant = focused ? 2 : 1
        // abc_textfield_default_mtrl_alpha carries its own 222/255 stroke alpha.
        if textView.isEditable {
            underline.backgroundColor = focused ? palette?.accent : palette?.secondaryText
            underline.alpha = focused ? 1 : 222 / 255
        } else {
            // TintHelper's disabled tint is additionally attenuated by abc_edit_text_material.
            let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
            underline.backgroundColor = ReaderPaletteColor.argb(isNight ? 0x4DFF_FFFF : 0x6100_0000)
            underline.alpha = (222 / 255) * (isNight ? 0.30 : 0.26)
        }
    }
}

private final class ReaderTocBookmarkGrowingTextView: UITextView {
    private var measuredWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let minimumHeight = (font?.lineHeight ?? 22) + textContainerInset.top + textContainerInset.bottom
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(minimumHeight))
        }
        let fitted = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(max(minimumHeight, fitted.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

final class ReaderTocBookmarkEditorFooter: UIView {
    let deleteButton = ReaderTocBookmarkFooterButton(type: .system)
    let cancelButton = ReaderTocBookmarkFooterButton(type: .system)
    let confirmButton = ReaderTocBookmarkFooterButton(type: .system)
    private let stack = UIStackView()
    private let rightActions = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        deleteButton.setTitle(L10n.Common.delete, for: .normal)
        cancelButton.setTitle(L10n.Common.cancel, for: .normal)
        deleteButton.accessibilityIdentifier = "reader.toc.bookmark.delete"
        cancelButton.accessibilityIdentifier = "reader.toc.bookmark.cancel"
        confirmButton.accessibilityIdentifier = "reader.toc.bookmark.confirm"
        confirmButton.setTitle(
            NSLocalizedString("reader.toc.bookmark.ok", value: "确认", comment: "Legado values-zh ok"),
            for: .normal)
        for button in [deleteButton, cancelButton, confirmButton] {
            button.backgroundColor = .clear
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        deleteButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightActions.axis = .horizontal
        rightActions.spacing = 0
        rightActions.addArrangedSubview(cancelButton)
        rightActions.addArrangedSubview(confirmButton)
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        stack.spacing = 0
        stack.addArrangedSubview(deleteButton)
        stack.addArrangedSubview(rightActions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightActions.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            deleteButton.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(frame:)")
    }

    func setDeletionAvailable(_ available: Bool) {
        // BookmarkDialog uses INVISIBLE for a new bookmark, retaining the left action's space.
        deleteButton.alpha = available ? 1 : 0
        deleteButton.isUserInteractionEnabled = available
        deleteButton.accessibilityElementsHidden = !available
        deleteButton.isEnabled = available
    }

    override func layoutSubviews() {
        updateAxis(for: bounds.width)
        super.layoutSubviews()
    }

    func updateAxis(for width: CGFloat) {
        let requiredWidth = [deleteButton, cancelButton, confirmButton].reduce(CGFloat(0)) {
            $0 + $1.intrinsicContentSize.width
        }
        let axis: NSLayoutConstraint.Axis = requiredWidth > width - 24 ? .vertical : .horizontal
        if stack.axis != axis {
            // Flexbox wraps two children, not three buttons. A wrapped pair starts at the row's leading edge.
            stack.axis = axis
            stack.alignment = axis == .vertical ? .leading : .fill
            stack.distribution = axis == .vertical ? .fill : .equalSpacing
        }
    }

    func applyFonts(traits: UITraitCollection) {
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        for button in [deleteButton, cancelButton, confirmButton] {
            button.titleLabel?.font = font
            button.contentEdgeInsets = UIEdgeInsets(
                top: 12 + padding.top, left: 12, bottom: 12 + padding.bottom, right: 12)
            button.invalidateIntrinsicContentSize()
        }
        setNeedsLayout()
    }

    func apply(palette: ReaderTocPalette) {
        for button in [deleteButton, cancelButton, confirmButton] {
            button.setTitleColor(palette.accent, for: .normal)
            button.setTitleColor(palette.accent.withAlphaComponent(0.38), for: .disabled)
        }
    }
}

final class ReaderTocBookmarkFooterButton: UIButton {
    private var measuredWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let natural = super.intrinsicContentSize
        guard bounds.width > 0, let titleLabel else { return natural }
        let textWidth = max(1, bounds.width - contentEdgeInsets.left - contentEdgeInsets.right)
        let textHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(
            width: natural.width, height: max(44, ceil(textHeight) + contentEdgeInsets.top + contentEdgeInsets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
