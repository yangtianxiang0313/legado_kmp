import UIKit

enum BookSourceEditorTypography {
    // AppCompat's medium text appearance is 18sp, with regular sans-serif weight.
    static func inputFont(compatibleWith traits: UITraitCollection) -> UIFont {
        scaledFont(ofSize: 18, textStyle: .body, compatibleWith: traits)
    }

    // TextInputLayout's TextAppearance.Design.Hint inherits AppCompat's 12sp caption.
    static func hintFont(compatibleWith traits: UITraitCollection) -> UIFont {
        scaledFont(ofSize: 12, textStyle: .caption1, compatibleWith: traits)
    }

    private static func scaledFont(
        ofSize size: CGFloat, textStyle: UIFont.TextStyle, compatibleWith traits: UITraitCollection
    ) -> UIFont {
        let scaledSize = max(
            size, UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size, compatibleWith: traits))
        return ReaderAndroidDefaultFont.font(size: scaledSize) ?? .systemFont(ofSize: scaledSize)
    }
}

final class BookSourceEditorSyntaxHighlighter: NSObject, NSTextStorageDelegate {
    private struct Rule {
        let expression: NSRegularExpression
        let color: UIColor

        init(_ pattern: String, color: UInt32) {
            expression = try! NSRegularExpression(pattern: pattern)
            self.color = UIColor(
                red: CGFloat((color >> 16) & 255) / 255,
                green: CGFloat((color >> 8) & 255) / 255,
                blue: CGFloat(color & 255) / 255,
                alpha: 1
            )
        }
    }

    private struct Request {
        let textVersion: UInt64
        let requestVersion: UInt64
        let source: String
    }

    // Only CodeViewExtensions' five expressions, in adapter registration order; not a parser.
    private static let rules = [
        Rule(#"\|\||&&|%%|@js:|@Json:|@css:|@@|@XPath:"#, color: 0xE65100),
        Rule(#""[A-Za-z0-9]*?"\:|"|\{|\}|\[|\]"#, color: 0x1565C0),
        Rule(#"\\n"#, color: 0x607D8B),
        Rule(#":|==|>|<|!=|>=|<=|->|=|%|-|-=|%=|\+|\-|\-=|\+=|\^|\&|\|::|\?|\*"#, color: 0xE65100),
        Rule("var", color: 0x039BE5),
    ]

    private weak var textView: UITextView?
    private var inputFont: UIFont
    private var textVersion: UInt64 = 0
    private var requestVersion: UInt64 = 0
    private var pendingWork: DispatchWorkItem?
    private var waitingForCommit = false
    private var immediateAfterCommit = false
    private var isPresentationActive = false
    private(set) var isApplyingAttributes = false

    init(textView: UITextView, font: UIFont) {
        self.textView = textView
        inputFont = font
        super.init()
        textView.textStorage.delegate = self
        refresh(immediately: true)
    }

    deinit {
        pendingWork?.cancel()
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard !isApplyingAttributes, editedMask.contains(.editedCharacters) else { return }
        textVersion &+= 1
        refresh(immediately: false)
    }

    func updateFont(_ font: UIFont) {
        inputFont = font
        refresh(immediately: true)
    }

    func setPresentationActive(_ active: Bool) {
        guard active != isPresentationActive else { return }
        isPresentationActive = active
        refresh(immediately: true)
    }

    func refresh(immediately: Bool) {
        pendingWork?.cancel()
        pendingWork = nil
        requestVersion &+= 1
        guard isPresentationActive, let textView else { return }
        guard textView.markedTextRange == nil else {
            waitingForCommit = true
            immediateAfterCommit = immediateAfterCommit || immediately
            return
        }

        waitingForCommit = false
        immediateAfterCommit = false
        let request = Request(
            textVersion: textVersion, requestVersion: requestVersion, source: textView.textStorage.string
        )
        if immediately {
            apply(request)
        } else {
            // Neither the work item nor its snapshot retains the editor or its row.
            let work = DispatchWorkItem { [weak self] in self?.apply(request) }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
        }
    }

    func compositionDidChange() {
        guard waitingForCommit, textView?.markedTextRange == nil else { return }
        refresh(immediately: immediateAfterCommit)
    }

    private func apply(_ request: Request) {
        guard isPresentationActive, request.textVersion == textVersion, request.requestVersion == requestVersion,
            let textView, textView.textStorage.string.utf16.elementsEqual(request.source.utf16)
        else { return }
        pendingWork = nil
        guard textView.markedTextRange == nil else {
            waitingForCommit = true
            return
        }

        let storage = textView.textStorage
        let fullRange = NSRange(location: 0, length: storage.length)
        let baseColor = AndroidReplicaTheme.primaryText.resolvedColor(with: textView.traitCollection)
        let undoManager = textView.undoManager
        let wasUndoEnabled = undoManager?.isUndoRegistrationEnabled == true
        isApplyingAttributes = true
        if wasUndoEnabled { undoManager?.disableUndoRegistration() }
        defer {
            if wasUndoEnabled { undoManager?.enableUndoRegistration() }
            isApplyingAttributes = false
        }

        // Attribute-only edits leave UTF-16 selection, marked text, and character undo history alone.
        storage.beginEditing()
        if fullRange.length > 0 {
            storage.addAttributes([.font: inputFont, .foregroundColor: baseColor], range: fullRange)
            if (1...1024).contains(fullRange.length) {
                for rule in Self.rules {
                    rule.expression.enumerateMatches(in: request.source, range: fullRange) { match, _, _ in
                        guard let match else { return }
                        storage.addAttribute(.foregroundColor, value: rule.color, range: match.range)
                    }
                }
            }
        }
        storage.endEditing()

        var typingAttributes = textView.typingAttributes
        typingAttributes[.font] = inputFont
        typingAttributes[.foregroundColor] = baseColor
        textView.typingAttributes = typingAttributes
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsLayout()
    }
}
