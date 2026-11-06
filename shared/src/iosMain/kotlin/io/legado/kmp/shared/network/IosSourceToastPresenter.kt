@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class)

package io.legado.kmp.shared.network

import kotlinx.cinterop.useContents
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSLock
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSRunLoop
import platform.Foundation.NSRunLoopCommonModes
import platform.Foundation.NSTimer
import platform.Foundation.setValue
import platform.Foundation.valueForKey
import platform.UIKit.NSLayoutConstraint
import platform.UIKit.NSLineBreakByTruncatingTail
import platform.UIKit.NSTextAlignmentCenter
import platform.UIKit.UIApplication
import platform.UIKit.UIApplicationDidBecomeActiveNotification
import platform.UIKit.UIApplicationDidEnterBackgroundNotification
import platform.UIKit.UIApplicationState.UIApplicationStateActive
import platform.UIKit.UIApplicationWillResignActiveNotification
import platform.UIKit.UIColor
import platform.UIKit.UIFont
import platform.UIKit.UILabel
import platform.UIKit.UISceneActivationStateForegroundActive
import platform.UIKit.UISceneDidActivateNotification
import platform.UIKit.UISceneWillDeactivateNotification
import platform.UIKit.UIView
import platform.UIKit.UIViewController
import platform.UIKit.UIWindowDidBecomeHiddenNotification
import platform.UIKit.UIWindowDidBecomeKeyNotification
import platform.UIKit.UIWindowLevelNormal
import platform.UIKit.accessibilityElementsHidden
import platform.UIKit.accessibilityViewIsModal
import platform.UIKit.isAccessibilityElement
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

internal object IosSourceToastPresenter {
    private val requestLock = NSLock()
    private var latestRequest = 0L
    private var currentToast: SourceToastView? = null
    private var timer: NSTimer? = null

    // These observers live with the singleton, including while no toast is visible.
    private val lifecycleObservers = listOf(
        UIApplicationWillResignActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UIApplicationDidBecomeActiveNotification,
        UISceneWillDeactivateNotification,
        UISceneDidActivateNotification,
        UIWindowDidBecomeKeyNotification,
        UIWindowDidBecomeHiddenNotification,
    ).map { name ->
        NSNotificationCenter.defaultCenter.addObserverForName(name, null, NSOperationQueue.mainQueue) {
            nextRequest()
            dismiss()
        }
    }

    fun show(message: String, durationMillis: Long, topViewController: () -> UIViewController?) {
        val request = nextRequest()
        val requestedAt = NSProcessInfo.processInfo.systemUptime
        val duration = durationMillis / 1_000.0
        // Coalesce concurrent sources before touching UIKit; never retain a pending host.
        dispatch_async(dispatch_get_main_queue()) {
            if (!isLatestRequest(request) || NSProcessInfo.processInfo.systemUptime - requestedAt >= duration) {
                return@dispatch_async
            }
            dismiss()
            val controller = topViewController() ?: return@dispatch_async
            val host = visibleHost(controller) ?: return@dispatch_async
            val toast = SourceToastView()
            val label = UILabel().apply {
                text = message
                font = UIFont.systemFontOfSize(14.0)
                textColor = UIColor.whiteColor
                textAlignment = NSTextAlignmentCenter
                numberOfLines = 4
                lineBreakMode = NSLineBreakByTruncatingTail
                userInteractionEnabled = false
                accessibilityViewIsModal = false
                setValue("source.toast.message", forKey = "accessibilityIdentifier")
                translatesAutoresizingMaskIntoConstraints = false
            }
            toast.apply {
                backgroundColor = UIColor.blackColor.colorWithAlphaComponent(0.82)
                layer.cornerRadius = 8.0
                clipsToBounds = true
                userInteractionEnabled = false
                isAccessibilityElement = false
                accessibilityViewIsModal = false
                setValue("source.toast", forKey = "accessibilityIdentifier")
                translatesAutoresizingMaskIntoConstraints = false
            }
            toast.addSubview(label)
            currentToast = toast
            toast.onDetached = { if (currentToast === toast) dismiss() }
            host.addSubview(toast)
            val safe = host.safeAreaLayoutGuide
            NSLayoutConstraint.activateConstraints(listOf(
                toast.centerXAnchor.constraintEqualToAnchor(safe.centerXAnchor),
                toast.leadingAnchor.constraintGreaterThanOrEqualToAnchor(safe.leadingAnchor, 20.0),
                toast.trailingAnchor.constraintLessThanOrEqualToAnchor(safe.trailingAnchor, -20.0),
                toast.widthAnchor.constraintLessThanOrEqualToConstant(360.0),
                toast.bottomAnchor.constraintEqualToAnchor(safe.bottomAnchor, -32.0),
                toast.topAnchor.constraintGreaterThanOrEqualToAnchor(safe.topAnchor, 12.0),
                label.leadingAnchor.constraintEqualToAnchor(toast.leadingAnchor, 16.0),
                label.trailingAnchor.constraintEqualToAnchor(toast.trailingAnchor, -16.0),
                label.topAnchor.constraintEqualToAnchor(toast.topAnchor, 10.0),
                label.bottomAnchor.constraintEqualToAnchor(toast.bottomAnchor, -10.0),
            ))
            val expiresAt = NSProcessInfo.processInfo.systemUptime + duration
            val expiryTimer = NSTimer.timerWithTimeInterval(0.1, repeats = true) { firingTimer ->
                // A callback from a replaced toast must never dismiss its successor.
                if (currentToast !== toast) {
                    firingTimer?.invalidate()
                } else {
                    // Keep the ObjC controller's bridge alive for this bounded presentation.
                    // A weak Kotlin wrapper can disappear while UIKit still owns its controller.
                    if (NSProcessInfo.processInfo.systemUptime >= expiresAt ||
                        topViewController() != controller || visibleHost(controller) != toast.superview
                    ) {
                        dismiss()
                    }
                }
            }
            timer = expiryTimer
            NSRunLoop.mainRunLoop.addTimer(expiryTimer, NSRunLoopCommonModes)
        }
    }

    private fun visibleHost(controller: UIViewController): UIView? {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            controller.isBeingDismissed() || controller.isBeingPresented() || controller.isMovingFromParentViewController()
        ) return null
        val host = controller.viewIfLoaded ?: return null
        val window = host.window ?: return null
        // The app-lock shield owns an elevated key window; source text must stay off it.
        if (!window.isKeyWindow() || window.windowLevel != UIWindowLevelNormal ||
            window.windowScene?.activationState != UISceneActivationStateForegroundActive ||
            !window.userInteractionEnabled
        ) return null
        var ancestor: UIView? = host
        while (ancestor != null) {
            if (ancestor.hidden || ancestor.alpha <= 0.01 || ancestor.accessibilityElementsHidden ||
                (ancestor.valueForKey("accessibilityIdentifier") as? String)?.startsWith("app-lock.") == true
            ) return null
            ancestor = ancestor.superview
        }
        return host.takeIf { it.bounds.useContents { size.width > 0.0 && size.height > 0.0 } }
    }

    private fun dismiss() {
        timer?.invalidate()
        timer = null
        val toast = currentToast
        currentToast = null
        toast?.onDetached = null
        toast?.removeFromSuperview()
    }

    private fun nextRequest(): Long {
        requestLock.lock()
        return try {
            ++latestRequest
        } finally {
            requestLock.unlock()
        }
    }

    private fun isLatestRequest(request: Long): Boolean {
        requestLock.lock()
        return try {
            latestRequest == request
        } finally {
            requestLock.unlock()
        }
    }
}

private class SourceToastView : UIView(frame = CGRectMake(0.0, 0.0, 0.0, 0.0)) {
    var onDetached: (() -> Unit)? = null

    override fun didMoveToWindow() {
        super.didMoveToWindow()
        if (window == null) onDetached?.invoke()
    }
}
