@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookSource
import kotlinx.cinterop.ObjCAction
import kotlinx.cinterop.useContents
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import platform.CoreGraphics.CGRectMake
import platform.CoreGraphics.CGSizeMake
import platform.Foundation.NSSelectorFromString
import platform.UIKit.NSLayoutConstraint
import platform.UIKit.UIActivityIndicatorView
import platform.UIKit.UIActivityIndicatorViewStyleMedium
import platform.UIKit.UIAlertController
import platform.UIKit.UIApplication
import platform.UIKit.UIButton
import platform.UIKit.UIButtonTypeSystem
import platform.UIKit.UIColor
import platform.UIKit.UIControlEventEditingChanged
import platform.UIKit.UIControlEventTouchUpInside
import platform.UIKit.UIControlStateNormal
import platform.UIKit.UIFont
import platform.UIKit.UIFontTextStyleBody
import platform.UIKit.UIFontTextStyleFootnote
import platform.UIKit.UIFontTextStyleHeadline
import platform.UIKit.UIImage
import platform.UIKit.UIImageView
import platform.UIKit.UILabel
import platform.UIKit.UILayoutConstraintAxisHorizontal
import platform.UIKit.UILayoutConstraintAxisVertical
import platform.UIKit.UIModalPresentationFormSheet
import platform.UIKit.UINavigationController
import platform.UIKit.UIReturnKeyType.UIReturnKeyDone
import platform.UIKit.UISceneActivationStateForegroundActive
import platform.UIKit.UIScrollView
import platform.UIKit.UIScrollViewDelegateProtocol
import platform.UIKit.UIScrollViewKeyboardDismissMode.UIScrollViewKeyboardDismissModeInteractive
import platform.UIKit.UIStackView
import platform.UIKit.UIStackViewAlignmentCenter
import platform.UIKit.UIStackViewDistributionFillEqually
import platform.UIKit.UITabBarController
import platform.UIKit.UITapGestureRecognizer
import platform.UIKit.UITextAutocapitalizationType.UITextAutocapitalizationTypeNone
import platform.UIKit.UITextAutocorrectionType.UITextAutocorrectionTypeNo
import platform.UIKit.UITextBorderStyle.UITextBorderStyleRoundedRect
import platform.UIKit.UITextField
import platform.UIKit.UITextFieldDelegateProtocol
import platform.UIKit.UITextFieldViewMode.UITextFieldViewModeWhileEditing
import platform.UIKit.UITextSmartDashesType.UITextSmartDashesTypeNo
import platform.UIKit.UITextSmartInsertDeleteType.UITextSmartInsertDeleteTypeNo
import platform.UIKit.UITextSmartQuotesType.UITextSmartQuotesTypeNo
import platform.UIKit.UITextSpellCheckingType.UITextSpellCheckingTypeNo
import platform.UIKit.UIView
import platform.UIKit.UIViewContentMode.UIViewContentModeScaleAspectFit
import platform.UIKit.UIViewController
import platform.UIKit.UIWindow
import platform.UIKit.UIWindowScene
import platform.UIKit.accessibilityLabel
import platform.UIKit.labelColor
import platform.UIKit.secondaryLabelColor
import platform.UIKit.systemBackgroundColor
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class IosSourceVerificationCodePrompt(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val headerResolver: SourceHeaderResolver,
) {
    suspend fun prompt(source: BookSource?, imageUrl: String): String {
        val checkedSource = requireNotNull(source) { "getVerificationResult parameter source cannot be null" }
        require(imageUrl.isNotBlank() && imageUrl.length < 64 * 1024) { "Invalid verification image URL" }
        return withContext(Dispatchers.Main.immediate) {
            // Android serializes source verification. Do not stack prompts from concurrent rules.
            presentationLock.withLock {
                suspendCancellableCoroutine { continuation ->
                    var controller: VerificationCodeController? = null
                    continuation.invokeOnCancellation {
                        dispatch_async(dispatch_get_main_queue()) {
                            controller?.cancelFromCaller()
                            controller = null
                        }
                    }
                    if (!continuation.isActive) return@suspendCancellableCoroutine
                    val presenter = verificationPresenter()
                    if (presenter == null || presenter is UIAlertController || presenter is VerificationCodeController || presenter.isBeingDismissed() ||
                        presenter.isBeingPresented() || presenter.viewIfLoaded?.window == null
                    ) {
                        continuation.resumeWithException(IllegalStateException("当前页面无法显示验证码"))
                        return@suspendCancellableCoroutine
                    }
                    val dialog = VerificationCodeController(
                        source = checkedSource,
                        imageUrl = imageUrl,
                        imageLoader = IosSourceVerificationCodePromptImageLoader(httpUseCase, cookieRepository, headerResolver),
                        parentJob = continuation.context[Job],
                        callerActive = { continuation.isActive },
                    ) { result ->
                        controller = null
                        if (continuation.isActive) {
                            result.fold(continuation::resume, continuation::resumeWithException)
                        }
                    }
                    controller = dialog
                    dialog.modalPresentationStyle = UIModalPresentationFormSheet
                    dialog.setPreferredContentSize(CGSizeMake(460.0, 420.0))
                    presenter.presentViewController(dialog, animated = true, completion = null)
                }
            }
        }
    }

    private companion object {
        val presentationLock = Mutex()
    }
}

private class VerificationCodeController(
    private val source: BookSource,
    private val imageUrl: String,
    private val imageLoader: IosSourceVerificationCodePromptImageLoader,
    parentJob: Job?,
    private val callerActive: () -> Boolean,
    onFinished: (Result<String>) -> Unit,
) : UIViewController(nibName = null, bundle = null), UITextFieldDelegateProtocol, UIScrollViewDelegateProtocol {
    private val scope = CoroutineScope(SupervisorJob(parentJob) + Dispatchers.Main.immediate)
    private var callback: ((Result<String>) -> Unit)? = onFinished
    private var finishResult: Result<String>? = null
    private var loadJob: Job? = null
    private var generation = 0L
    private var closed = false
    private var started = false
    private var loading = false
    private var lastVisibleHeight = 0.0
    private var lastImageWidth = 0.0
    private val contentScroll = UIScrollView()
    private val imageScroll = UIScrollView()
    private val imageView = UIImageView()
    private val input = UITextField()
    private val status = UILabel()
    private val spinner = UIActivityIndicatorView(activityIndicatorStyle = UIActivityIndicatorViewStyleMedium)
    private val refresh = UIButton.buttonWithType(UIButtonTypeSystem)
    private val cancel = UIButton.buttonWithType(UIButtonTypeSystem)
    private val confirm = UIButton.buttonWithType(UIButtonTypeSystem)

    override fun viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackgroundColor
        val heading = UILabel().apply {
            text = "输入验证码"
            font = UIFont.preferredFontForTextStyle(UIFontTextStyleHeadline)
            adjustsFontForContentSizeCategory = true
            numberOfLines = 0
            textColor = UIColor.labelColor
        }
        configureButton(refresh, "刷新", "arrow.clockwise", "refreshImage")
        val header = UIStackView(arrangedSubviews = listOf(heading, refresh)).apply {
            axis = UILayoutConstraintAxisHorizontal
            alignment = UIStackViewAlignmentCenter
            spacing = 12.0
        }
        val sourceName = UILabel().apply {
            text = source.bookSourceName
            font = UIFont.preferredFontForTextStyle(UIFontTextStyleFootnote)
            adjustsFontForContentSizeCategory = true
            numberOfLines = 0
            textColor = UIColor.secondaryLabelColor
        }
        imageScroll.apply {
            clipsToBounds = true
            // Transparent captcha pixels need a white backing even when the sheet is dark.
            backgroundColor = UIColor.whiteColor
            minimumZoomScale = 1.0
            maximumZoomScale = 4.0
            delegate = this@VerificationCodeController
            accessibilityLabel = "验证码图片"
        }
        imageView.apply {
            contentMode = UIViewContentModeScaleAspectFit
            accessibilityLabel = "验证码图片"
            userInteractionEnabled = true
            addGestureRecognizer(UITapGestureRecognizer(
                target = this@VerificationCodeController,
                action = NSSelectorFromString("toggleImageZoom"),
            ))
        }
        imageScroll.addSubview(imageView)
        imageScroll.heightAnchor.constraintEqualToConstant(100.0).active = true
        status.apply {
            font = UIFont.preferredFontForTextStyle(UIFontTextStyleFootnote)
            adjustsFontForContentSizeCategory = true
            numberOfLines = 0
            textColor = UIColor.secondaryLabelColor
        }
        input.apply {
            placeholder = "验证码"
            accessibilityLabel = "验证码"
            font = UIFont.preferredFontForTextStyle(UIFontTextStyleBody)
            setAdjustsFontForContentSizeCategory(true)
            textColor = UIColor.labelColor
            borderStyle = UITextBorderStyleRoundedRect
            setAutocapitalizationType(UITextAutocapitalizationTypeNone)
            setAutocorrectionType(UITextAutocorrectionTypeNo)
            setSpellCheckingType(UITextSpellCheckingTypeNo)
            setSmartQuotesType(UITextSmartQuotesTypeNo)
            setSmartDashesType(UITextSmartDashesTypeNo)
            setSmartInsertDeleteType(UITextSmartInsertDeleteTypeNo)
            setReturnKeyType(UIReturnKeyDone)
            clearButtonMode = UITextFieldViewModeWhileEditing
            delegate = this@VerificationCodeController
            addTarget(this@VerificationCodeController, NSSelectorFromString("inputChanged"), UIControlEventEditingChanged)
        }
        input.heightAnchor.constraintGreaterThanOrEqualToConstant(48.0).active = true
        configureButton(cancel, "取消", "xmark", "cancelEntry")
        configureButton(confirm, "确认", "checkmark", "confirmEntry")
        confirm.enabled = false
        val actions = UIStackView(arrangedSubviews = listOf(cancel, confirm)).apply {
            axis = UILayoutConstraintAxisHorizontal
            distribution = UIStackViewDistributionFillEqually
            spacing = 16.0
            translatesAutoresizingMaskIntoConstraints = false
        }
        val progress = UIStackView(arrangedSubviews = listOf(spinner, status)).apply {
            axis = UILayoutConstraintAxisHorizontal
            alignment = UIStackViewAlignmentCenter
            spacing = 8.0
        }
        val content = UIStackView(arrangedSubviews = listOf(header, sourceName, imageScroll, progress, input)).apply {
            axis = UILayoutConstraintAxisVertical
            spacing = 16.0
            translatesAutoresizingMaskIntoConstraints = false
        }
        contentScroll.apply {
            translatesAutoresizingMaskIntoConstraints = false
            keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive
            alwaysBounceVertical = true
        }
        view.addSubview(contentScroll)
        view.addSubview(actions)
        contentScroll.addSubview(content)
        val safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activateConstraints(listOf(
            contentScroll.leadingAnchor.constraintEqualToAnchor(safe.leadingAnchor, 20.0),
            contentScroll.trailingAnchor.constraintEqualToAnchor(safe.trailingAnchor, -20.0),
            contentScroll.topAnchor.constraintEqualToAnchor(safe.topAnchor, 20.0),
            contentScroll.bottomAnchor.constraintEqualToAnchor(actions.topAnchor, -12.0),
            actions.leadingAnchor.constraintEqualToAnchor(safe.leadingAnchor, 20.0),
            actions.trailingAnchor.constraintEqualToAnchor(safe.trailingAnchor, -20.0),
            actions.bottomAnchor.constraintEqualToAnchor(view.keyboardLayoutGuide.topAnchor, -12.0),
            content.leadingAnchor.constraintEqualToAnchor(contentScroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraintEqualToAnchor(contentScroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraintEqualToAnchor(contentScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraintEqualToAnchor(contentScroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraintEqualToAnchor(contentScroll.frameLayoutGuide.widthAnchor),
        ))
    }

    override fun viewDidAppear(animated: Boolean) {
        super.viewDidAppear(animated)
        if (closed) return
        if (!callerActive()) {
            cancelFromCaller()
        } else if (!started) {
            started = true
            refreshImage()
            input.becomeFirstResponder()
        }
    }

    override fun viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        val imageWidth = imageScroll.bounds.useContents { size.width }
        if (imageWidth != lastImageWidth) {
            lastImageWidth = imageWidth
            resetImageZoom()
        }
        val height = contentScroll.bounds.useContents { size.height }
        if (height != lastVisibleHeight) {
            lastVisibleHeight = height
            if (input.isFirstResponder()) {
                contentScroll.scrollRectToVisible(input.convertRect(input.bounds, toView = contentScroll), animated = false)
            }
        }
    }

    override fun viewDidDisappear(animated: Boolean) {
        super.viewDidDisappear(animated)
        if (!closed) finish(Result.failure(IllegalStateException("验证码输入已取消")), dismiss = false)
        deliverResult()
    }

    override fun textFieldShouldReturn(textField: UITextField): Boolean {
        if (textField.markedTextRange() == null) confirmEntry()
        return false
    }

    override fun viewForZoomingInScrollView(scrollView: UIScrollView): UIView? =
        imageView.takeIf { scrollView == imageScroll && imageView.image != null }

    @ObjCAction
    fun inputChanged() {
        confirm.enabled = !closed && !loading && imageView.image != null &&
            !input.text.isNullOrBlank() && input.markedTextRange() == null
    }

    @ObjCAction
    fun refreshImage() {
        if (closed || !callerActive()) return
        val requestGeneration = ++generation
        loadJob?.cancel()
        loading = true
        input.text = ""
        imageView.image = null
        resetImageZoom()
        confirm.enabled = false
        refresh.hidden = true
        status.text = "正在加载验证码"
        spinner.startAnimating()
        loadJob = scope.launch {
            fun current() = !closed && generation == requestGeneration && callerActive()
            try {
                val image = imageLoader.load(source, imageUrl) {
                    ensureActive()
                    if (!current()) throw CancellationException("Verification image superseded")
                }
                ensureActive()
                if (!current()) return@launch
                imageView.image = image
                resetImageZoom()
                status.text = null
            } catch (_: Exception) {
                // A request timeout is retryable; a cancelled/superseded coroutine is not.
                ensureActive()
                if (!current()) return@launch
                status.text = "验证码图片加载失败"
                refresh.hidden = false
                refresh.setTitle("重试", forState = UIControlStateNormal)
                refresh.accessibilityLabel = "重试加载验证码"
            } finally {
                if (current()) {
                    loading = false
                    spinner.stopAnimating()
                    inputChanged()
                }
            }
        }
    }

    @ObjCAction
    fun toggleImageZoom() {
        if (closed || imageView.image == null) return
        imageScroll.setZoomScale(if (imageScroll.zoomScale > 1.0) 1.0 else 2.0, animated = true)
    }

    @ObjCAction
    fun confirmEntry() {
        if (closed || !callerActive() || loading || imageView.image == null || input.markedTextRange() != null) return
        val value = input.text.orEmpty()
        if (value.isBlank()) {
            input.becomeFirstResponder()
            return
        }
        // Preserve the entered text, matching Android; do not silently trim captcha characters.
        finish(Result.success(value), dismiss = true)
    }

    @ObjCAction
    fun cancelEntry() {
        finish(Result.failure(IllegalStateException("验证码输入已取消")), dismiss = true)
    }

    fun cancelFromCaller() {
        finish(Result.failure(CancellationException("Verification code caller cancelled")), dismiss = true)
    }

    private fun resetImageZoom() {
        imageScroll.setZoomScale(1.0, animated = false)
        val width = imageScroll.bounds.useContents { size.width }
        val height = imageScroll.bounds.useContents { size.height }
        imageView.setFrame(CGRectMake(0.0, 0.0, width, height))
        imageScroll.setContentSize(CGSizeMake(width, height))
    }

    private fun configureButton(button: UIButton, text: String, symbol: String, action: String) {
        button.apply {
            setTitle(text, forState = UIControlStateNormal)
            setImage(UIImage.systemImageNamed(symbol), forState = UIControlStateNormal)
            accessibilityLabel = text
            titleLabel?.apply {
                font = UIFont.preferredFontForTextStyle(UIFontTextStyleBody)
                adjustsFontForContentSizeCategory = true
                numberOfLines = 0
            }
            heightAnchor.constraintGreaterThanOrEqualToConstant(44.0).active = true
            addTarget(this@VerificationCodeController, NSSelectorFromString(action), UIControlEventTouchUpInside)
        }
    }

    private fun finish(result: Result<String>, dismiss: Boolean) {
        if (closed) return
        closed = true
        generation++
        finishResult = result
        loadJob?.cancel()
        loadJob = null
        scope.cancel()
        input.resignFirstResponder()
        input.delegate = null
        input.text = null
        imageScroll.delegate = null
        imageView.image = null
        spinner.stopAnimating()
        confirm.enabled = false
        refresh.enabled = false
        cancel.enabled = false
        if (dismiss && presentingViewController != null) {
            dismissViewControllerAnimated(true) { deliverResult() }
        } else {
            deliverResult()
        }
    }

    private fun deliverResult() {
        val result = finishResult ?: return
        val complete = callback ?: return
        callback = null
        finishResult = null
        // Let UIKit finish detaching the sheet before a queued prompt acquires the lock.
        dispatch_async(dispatch_get_main_queue()) { complete(result) }
    }
}

private fun verificationPresenter(): UIViewController? {
    val windows = UIApplication.sharedApplication.connectedScenes.filterIsInstance<UIWindowScene>()
        .filter { it.activationState == UISceneActivationStateForegroundActive }
        .flatMap { it.windows.filterIsInstance<UIWindow>() }
    val window = windows.firstOrNull { it.isKeyWindow() && !it.hidden } ?: return null
    var controller = window.rootViewController ?: return null
    while (true) {
        controller = controller.presentedViewController
            ?: (controller as? UINavigationController)?.visibleViewController
            ?: (controller as? UITabBarController)?.selectedViewController
            ?: return controller
    }
}
