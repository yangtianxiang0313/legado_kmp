import SafariServices
import UIKit

/// TextDialog("html", text), dialog_text_view.xml and dialog_text.xml at Legado 5f5d314.
final class BookSourceDebugRawViewController: UIViewController, NavigationContentChromeProviding, UITextViewDelegate {
    var isContentCurrent: (() -> Bool)?
    var onClose: (() -> Void)?
    private let rawText: String
    private let dialogTitle: String
    private let rendersHelp: Bool
    private var helpHTML: String?
    private var helpDocument: NSAttributedString?
    private let outsideControl = UIControl()
    private let panel = UIView()
    private let viewport = UIScrollView()
    private let contentView = UIView()
    private let toolbar = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
    private let textView = UITextView()
    private var closeTouchArmed = false
    private var isCancellingCloseTouch = false
    private var isClosing = false
    private var isVisible = false
    private var previousNavigationBarHidden: Bool?
    private var contentTask: Task<Void, Never>?
    private var contentGeneration = UUID()
    private var didApplyText = false
    private var didNotifyClose = false
    private var environmentActive = true

    init(text: String, title: String = "html", rendersHelp: Bool = false) {
        rawText = text
        dialogTitle = title
        self.rendersHelp = rendersHelp
        super.init(nibName: nil, bundle: nil)
        self.title = title
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    convenience init(helpHTML: String) {
        self.init(text: "", title: "帮助")
        self.helpHTML = helpHTML
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        contentTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(ReaderTocPalette(traits: traitCollection).titleBackground) ? .darkContent : .lightContent
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleBack))
        escape.discoverabilityTitle = "关闭"
        escape.wantsPriorityOverSystemBehavior = true
        let back = UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(handleBack))
        back.discoverabilityTitle = "返回"
        return [escape, back]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIScene.willDeactivateNotification,
            UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIWindow.didBecomeKeyNotification,
            UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        configureViews()
        applyTypographyAndPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController {
            if previousNavigationBarHidden == nil {
                previousNavigationBarHidden = navigationController.isNavigationBarHidden
            }
            navigationController.setNavigationBarHidden(true, animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isClosing = false
        isVisible = true
        scheduleContent()
        DispatchQueue.main.async { [weak self] in self?.scheduleContent() }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        cancelContent()
        invalidateCloseTouch()
        resignFirstResponder()
        if isMovingFromParent, let previousNavigationBarHidden {
            navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.main.async { [weak self] in self?.notifyCloseIfDetached() }
    }

    private func cancelContent() {
        contentGeneration = UUID()
        contentTask?.cancel()
        contentTask = nil
    }

    private func scheduleContent() {
        guard !didApplyText, contentTask == nil, canApplyContent else { return }
        let generation = contentGeneration
        contentTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.contentGeneration == generation else { return }
            self.contentTask = nil
            guard self.canApplyContent else { return }
            // Apply the captured raw response only; never resolve the owner's latest query here.
            if let html = self.helpHTML {
                do {
                    let document = try ReaderDictionaryDialogHTMLRenderer.render(html)
                    guard !Task.isCancelled, self.contentGeneration == generation, self.canApplyContent else { return }
                    self.helpDocument = document
                    self.textView.attributedText = ReaderDictionaryDialogHTMLRenderer.styled(document, traits: self.traitCollection)
                } catch is CancellationError {
                    return
                } catch {
                    self.textView.text = error.userFacingMessage
                    SharedRuntime.log("Source rule help rendering failed: \(error.localizedDescription)")
                }
            } else {
                self.textView.text = self.rawText
            }
            self.didApplyText = true
            if self.rendersHelp || self.helpDocument != nil { self.applyTypographyAndPalette() }
        }
    }

    private var canApplyContent: Bool {
        guard isVisible, !isClosing, environmentActive, isContentCurrent?() != false,
            let window = viewIfLoaded?.window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            !isBeingDismissed, !isMovingFromParent, presentedViewController == nil
        else { return false }
        if let navigationController { return navigationController.topViewController === self }
        return presentingViewController?.presentedViewController === self
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        let suspended = [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
        ].contains(notification.name)
        environmentActive = !suspended
        invalidateCloseTouch()
        if suspended {
            cancelContent()
        } else {
            scheduleContent()
        }
    }

    private func notifyCloseIfDetached() {
        guard !didNotifyClose, presentingViewController == nil,
            navigationController?.viewControllers.contains(where: { $0 === self }) != true
        else { return }
        didNotifyClose = true
        cancelContent()
        let completion = onClose
        onClose = nil
        completion?()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        handleBack()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyTypographyAndPalette()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let horizontalInset = min(16, max(0, (safe.width - 1) / 2))
        let width = max(0, safe.width - horizontalInset * 2)
        let height = min(max(0, safe.height - 32), view.bounds.height * 0.9)
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        viewport.frame = panel.bounds
        guard width > 0 else { return }

        let actionWidth = min(width / 2, max(48, ceil(closeButton.titleLabel?.intrinsicContentSize.width ?? 0) + 32))
        let titleWidth = max(1, width - actionWidth - 32)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let actionHeight = ceil(
            closeButton.titleLabel?.sizeThatFits(
                CGSize(width: max(1, actionWidth - 16), height: .greatestFiniteMagnitude)
            ).height ?? 0)
        let toolbarHeight = max(56, max(titleHeight, actionHeight) + 16)
        let contentHeight = max(height, toolbarHeight + 44)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel.frame = CGRect(
            x: rtl ? actionWidth + 16 : 16, y: 8, width: titleWidth, height: toolbarHeight - 16)
        closeButton.frame = CGRect(x: rtl ? 0 : width - actionWidth, y: 0, width: actionWidth, height: toolbarHeight)
        textView.frame = CGRect(x: 0, y: toolbarHeight, width: width, height: contentHeight - toolbarHeight)
        // Only exceptionally short windows scroll the toolbar together with the body.
        viewport.contentSize = contentView.bounds.size
        viewport.isScrollEnabled = contentHeight > height
        let offset = CGPoint(x: 0, y: min(max(0, viewport.contentOffset.y), max(0, contentHeight - height)))
        if viewport.contentOffset != offset { viewport.setContentOffset(offset, animated: false) }
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookSource.debug.raw.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(closeTouchBegan), for: .touchDown)
        outsideControl.addTarget(self, action: #selector(closeTouchEnded(_:event:)), for: .touchUpInside)
        panel.layer.cornerRadius = 2
        panel.clipsToBounds = true

        titleLabel.text = dialogTitle
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookSource.debug.raw.title"
        closeButton.configuration = nil
        closeButton.setTitle("关闭", for: .normal)
        closeButton.titleLabel?.numberOfLines = 1
        closeButton.titleLabel?.textAlignment = .center
        closeButton.titleLabel?.lineBreakMode = .byTruncatingTail
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = false
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        closeButton.accessibilityIdentifier = "bookSource.debug.raw.close"
        closeButton.isExclusiveTouch = true
        closeButton.addTarget(self, action: #selector(closeTouchBegan), for: .touchDown)
        closeButton.addTarget(self, action: #selector(closeTouchEnded(_:event:)), for: .touchUpInside)
        for control in [outsideControl, closeButton] {
            control.addTarget(self, action: #selector(invalidateCloseTouch), for: [.touchCancel, .touchUpOutside])
        }

        // Keep the original string, not an HTML import or a response preview.
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.contentInsetAdjustmentBehavior = .never
        textView.alwaysBounceVertical = false
        textView.scrollsToTop = false
        textView.accessibilityLabel = dialogTitle
        textView.accessibilityIdentifier = "bookSource.debug.raw.text"
        viewport.contentInsetAdjustmentBehavior = .never
        viewport.showsHorizontalScrollIndicator = false
        viewport.alwaysBounceVertical = false
        viewport.scrollsToTop = false
        view.addSubview(outsideControl)
        view.addSubview(panel)
        panel.addSubview(viewport)
        viewport.addSubview(contentView)
        contentView.addSubview(toolbar)
        contentView.addSubview(textView)
        textView.delegate = self
        if helpHTML != nil { textView.accessibilityIdentifier = "sourceEdit.ruleHelp.document" }
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(closeButton)
        view.accessibilityElements = [titleLabel, closeButton, textView]
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        applyTypographyAndPalette(updateTypography: false)
    }

    private func applyTypographyAndPalette(updateTypography: Bool = true) {
        let palette = ReaderTocPalette(traits: traitCollection)
        panel.backgroundColor = palette.background
        toolbar.backgroundColor = palette.titleBackground
        titleLabel.textColor = palette.toolbarText
        if updateTypography {
            titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
                size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        }
        closeButton.setTitleColor(palette.toolbarText, for: .normal)
        if updateTypography {
            closeButton.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        }
        let selection = textView.selectedRange
        let offset = textView.contentOffset
        textView.backgroundColor = palette.background
        if let helpDocument {
            if updateTypography { textView.attributedText = ReaderDictionaryDialogHTMLRenderer.styled(helpDocument, traits: traitCollection) }
        } else if updateTypography {
            let font = ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
            if textView.font != font { textView.font = font }
            let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
            textView.textContainerInset = UIEdgeInsets(
                top: 12 + padding.top, left: 12, bottom: 12 + padding.bottom, right: 12)
        }
        textView.textColor = palette.secondaryText
        textView.linkTextAttributes = [.foregroundColor: palette.accent]
        if rendersHelp, didApplyText { applyHelpAppearance(palette: palette) }
        textView.tintColor = palette.accent
        textView.indicatorStyle = ReaderPaletteColor.isNightResource(traits: traitCollection) ? .white : .black
        if textView.selectedRange != selection { textView.selectedRange = selection }
        if !textView.isTracking, !textView.isDecelerating, textView.contentOffset != offset {
            textView.setContentOffset(offset, animated: false)
        }
        setNeedsStatusBarAppearanceUpdate()
        if updateTypography { view.setNeedsLayout() }
    }

    private func applyHelpAppearance(palette: ReaderTocPalette) {
        let storage = textView.textStorage
        let string = storage.string as NSString
        let bodyFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        let codeFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedSystemFont(ofSize: 14, weight: .regular), compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        storage.beginEditing()
        storage.setAttributes(
            [.font: bodyFont, .foregroundColor: palette.secondaryText, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: string.length))
        let headingRange = string.range(of: "书源调试")
        if headingRange.location != NSNotFound {
            let headingFont = ReaderAndroidDefaultFont.scaledFont(
                size: 28, textStyle: .title1, weight: 700, compatibleWith: traitCollection)
            storage.addAttribute(.font, value: headingFont, range: headingRange)
        }
        for section in BookSourceDebugScreenAdapter.helpSections {
            let range = string.range(of: section.example)
            if range.location != NSNotFound { storage.addAttribute(.font, value: codeFont, range: range) }
        }
        storage.endEditing()
    }

    func textView(
        _ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        guard helpDocument != nil, canClose, isContentCurrent?() != false,
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return false }
        present(SFSafariViewController(url: url), animated: true)
        return false
    }

    private var canClose: Bool {
        guard isVisible, !isClosing, environmentActive, let window = viewIfLoaded?.window,
            window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active, !view.isHidden, view.alpha > 0.01,
            presentedViewController == nil, !isBeingDismissed, !isBeingPresented,
            !isMovingFromParent, transitionCoordinator == nil
        else { return false }
        if let navigationController {
            guard navigationController.topViewController === self,
                navigationController.transitionCoordinator == nil,
                !navigationController.isBeingDismissed, !navigationController.isBeingPresented,
                navigationController.presentedViewController == nil
            else { return false }
            if let owner = navigationController.presentingViewController {
                return owner.presentedViewController === navigationController
            }
            return navigationController.viewControllers.count > 1
        }
        guard let owner = presentingViewController else { return false }
        return owner.presentedViewController === self && owner.transitionCoordinator == nil
    }

    @objc private func closeTouchBegan() { closeTouchArmed = canClose }

    @objc private func invalidateCloseTouch() {
        closeTouchArmed = false
        // UIKit sends touchCancel synchronously from cancelTracking.
        guard !isCancellingCloseTouch else { return }
        isCancellingCloseTouch = true
        defer { isCancellingCloseTouch = false }
        outsideControl.cancelTracking(with: nil)
        closeButton.cancelTracking(with: nil)
    }

    @objc private func closeTouchEnded(_ sender: UIControl, event: UIEvent?) {
        // VoiceOver/keyboard activation has no touch; it still passes the current-owner checks.
        let allowed = event?.allTouches?.isEmpty != false || closeTouchArmed
        closeTouchArmed = false
        if allowed { handleBack() }
    }

    @objc private func handleBack() {
        guard canClose else { return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        if let navigationController, navigationController.topViewController === self,
            navigationController.viewControllers.count > 1
        {
            isClosing = true
            navigationController.popViewController(animated: animated)
        } else if let navigationController, navigationController.presentingViewController != nil {
            isClosing = true
            navigationController.dismiss(animated: animated) { [weak self] in self?.notifyCloseIfDetached() }
        } else if presentingViewController != nil {
            isClosing = true
            dismiss(animated: animated) { [weak self] in self?.notifyCloseIfDetached() }
        }
    }
}
