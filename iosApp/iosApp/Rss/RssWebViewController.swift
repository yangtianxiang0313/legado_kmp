import UIKit
import WebKit
import Photos
import AVFoundation
import shared

/// F16/F17/F18/F19: RSS WebView 内容渲染控制器
/// 对齐 Android ReadRssActivity，使用 WKWebView 渲染 HTML 内容，
/// 支持 RssSource.style CSS 注入、injectJs JS 注入、长按图片保存到相册、TTS 朗读。
final class RssWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, AVSpeechSynthesizerDelegate {

    private let article: RssArticle
    private let source: RssSource?
    private let screen: RssScreenAdapter
    private let initialFavorites: [RssStar]
    private var isFavorite = false

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }()
    private let stateView = ContentStateView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?

    // F19: TTS 朗读
    private let synthesizer = AVSpeechSynthesizer()
    private var isSpeaking = false
    private var readAloudItem: UIBarButtonItem?

    init(article: RssArticle, source: RssSource?, screen: RssScreenAdapter, favorites: [RssStar]) {
        self.article = article
        self.source = source
        self.screen = screen
        self.initialFavorites = favorites
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = article.title.isEmpty ? L10n.RSS.articleReaderTitle : article.title

        synthesizer.delegate = self
        setupWebView()
        setupProgressView()
        setupStateView()
        setupNavigation()
        setupLongPressGesture()
        loadContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }

    deinit {
        progressObservation?.invalidate()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Setup

    private func setupWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupProgressView() {
        progressView.tintColor = .systemBlue
        progressView.trackTintColor = .clear
        view.addSubview(progressView)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            let progress = Float(webView.estimatedProgress)
            self?.progressView.setProgress(progress, animated: true)
            self?.progressView.isHidden = progress >= 1.0
        }
    }

    private func setupStateView() {
        stateView.setTestingIdentifier("rss_web_state")
        view.addSubview(stateView)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupNavigation() {
        let favoriteItem = UIBarButtonItem(
            title: L10n.RSS.markFavorite,
            style: .plain,
            target: self,
            action: #selector(toggleFavorite)
        )
        favoriteItem.accessibilityIdentifier = UIIdentifiers.RSS.articleFavoriteButton
        isFavorite = initialFavorites.contains(where: { $0.origin == article.origin && $0.link == article.link })
        favoriteItem.title = isFavorite ? L10n.RSS.unmarkFavorite : L10n.RSS.markFavorite

        // F19: TTS 朗读按钮
        let ttsItem = UIBarButtonItem(
            image: UIImage(systemName: "play.circle"),
            style: .plain,
            target: self,
            action: #selector(toggleReadAloud)
        )
        ttsItem.accessibilityIdentifier = "rss.readAloudButton"
        readAloudItem = ttsItem

        var moreActions: [UIAction] = []
        if !article.link.isEmpty {
            let link = article.link
            moreActions.append(UIAction(title: L10n.RSS.shareLink, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self, let url = URL(string: link) else { return }
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                self.present(activityVC, animated: true)
            })
            moreActions.append(UIAction(title: L10n.RSS.openInBrowser, image: UIImage(systemName: "safari")) { _ in
                guard let url = URL(string: link) else { return }
                UIApplication.shared.open(url)
            })
        }
        if moreActions.isEmpty {
            navigationItem.rightBarButtonItems = [ttsItem, favoriteItem]
        } else {
            let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: moreActions))
            navigationItem.rightBarButtonItems = [moreItem, ttsItem, favoriteItem]
        }
    }

    // MARK: - F18 长按图片保存

    private func setupLongPressGesture() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        webView.addGestureRecognizer(longPress)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: webView)
        // 对齐 Android hitTestResult: 使用 JS 检测点击位置的图片元素
        let js = """
        (function() {
            var el = document.elementFromPoint(\(point.x), \(point.y));
            if (el && el.tagName === 'IMG') return el.src;
            if (el) {
                var img = el.querySelector('img');
                if (img) return img.src;
                var parent = el.parentElement;
                if (parent && parent.tagName === 'IMG') return parent.src;
            }
            return '';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let urlString = result as? String, !urlString.isEmpty else { return }
            self.showSaveImageMenu(imageURL: urlString)
        }
    }

    /// 对齐 Android 长按图片弹出菜单（保存图片 / 选择目录）
    private func showSaveImageMenu(imageURL: String) {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.RSS.saveImage, style: .default) { [weak self] _ in
            self?.downloadAndSaveImage(urlString: imageURL)
        })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
    }

    private func downloadAndSaveImage(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        // 检查相册权限
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            performImageDownload(url: url)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.performImageDownload(url: url)
                    } else {
                        self?.showTransientMessage(L10n.RSS.saveImagePermissionDenied)
                    }
                }
            }
        default:
            showTransientMessage(L10n.RSS.saveImagePermissionDenied)
        }
    }

    private func performImageDownload(url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil, let image = UIImage(data: data) else {
                    self.showTransientMessage(L10n.RSS.saveImageFailed)
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, self, #selector(self.imageSaveCompletion(_:didFinishSavingWithError:contextInfo:)), nil)
            }
        }.resume()
    }

    @objc private func imageSaveCompletion(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        if error != nil {
            showTransientMessage(L10n.RSS.saveImageFailed)
        } else {
            showTransientMessage(L10n.RSS.saveImageSuccess)
        }
    }

    // MARK: - Content Loading

    private func loadContent() {
        // 如果文章已有 content，直接渲染
        if let content = article.content, !content.isEmpty {
            renderHTML(content)
            return
        }
        // 如果没有 source，展示 description
        guard let source else {
            renderHTML(article.description_ ?? "")
            return
        }

        stateView.showLoading(message: L10n.RSS.loadingContent)
        Task { [weak self] in
            do {
                guard let self else { return }
                let content = try await self.screen.loadContent(article: self.article, source: source)
                await MainActor.run {
                    self.stateView.hide()
                    self.renderHTML(content)
                }
            } catch {
                await MainActor.run {
                    self?.stateView.showMessage(
                        title: L10n.RSS.contentFailed,
                        message: error.userFacingMessage,
                        actionTitle: L10n.Common.retry
                    ) { [weak self] in
                        self?.loadContent()
                    }
                }
            }
        }
    }

    // MARK: - F16/F17 HTML 渲染 + 样式注入

    /// 对齐 Android ReadRssViewModel.clHtml()：
    /// - RssSource.style 非空时注入自定义 CSS
    /// - 否则如果内容本身不含 <style>，注入默认的图片/视频/body 自适应样式
    /// 对齐 Android onPageFinished 中的 injectJs 注入
    private func renderHTML(_ content: String) {
        let html = wrapHTML(content)

        // F17: injectJs 注入（对齐 Android onPageFinished 中的 evaluateJavascript）
        if let injectJs = source?.injectJs, !injectJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let userScript = WKUserScript(
                source: injectJs,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }

        // 对齐 Android loadDataWithBaseURL：
        // loadWithBaseUrl == true 时使用文章链接作为 baseURL
        let baseURL: URL?
        if source?.loadWithBaseUrl == true, !article.link.isEmpty {
            baseURL = URL(string: article.link)
        } else {
            baseURL = nil
        }

        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// 对齐 Android ReadRssViewModel.clHtml() 的三种情况
    private func wrapHTML(_ content: String) -> String {
        // 情况 1: RssSource.style 非空，注入自定义 CSS
        if let style = source?.style, !style.isEmpty {
            return """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
            <style>\(style)</style></head><body>\(content)</body></html>
            """
        }
        // 情况 2: 内容已包含 <style>，直接使用
        if content.range(of: "<style>", options: .caseInsensitive) != nil {
            // 仍然包裹 viewport meta 以确保移动端适配
            if content.range(of: "<html", options: .caseInsensitive) != nil {
                return content
            }
            return """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
            </head><body>\(content)</body></html>
            """
        }
        // 情况 3: 注入默认样式（对齐 Android 默认 CSS）
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
            img{max-width:100% !important; width:auto; height:auto;}
            video{object-fit:fill; max-width:100% !important; width:auto; height:auto;}
            body{word-wrap:break-word; height:auto;max-width: 100%; width:auto;}
        </style></head><body>\(content)</body></html>
        """
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 更新标题（对齐 Android onPageFinished）
        if let pageTitle = webView.title,
           !pageTitle.isEmpty,
           pageTitle != webView.url?.absoluteString {
            title = pageTitle
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // 初始加载 about:blank 或 loadHTMLString 时直接允许
        guard let url = navigationAction.request.url,
              navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        // 点击链接时在外部浏览器打开（对齐 Android shouldOverrideUrlLoading 对 http/https 的处理）
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    // MARK: - F19 TTS 朗读

    @objc private func toggleReadAloud() {
        if synthesizer.isSpeaking {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
                isSpeaking = true
                updateReadAloudButton()
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isSpeaking = false
                updateReadAloudButton()
            }
        } else {
            extractTextAndSpeak()
        }
    }

    private func extractTextAndSpeak() {
        let js = "document.body.innerText || document.body.textContent || ''"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            // 尝试使用中文语音
            if let voice = AVSpeechSynthesisVoice(language: "zh-CN") {
                utterance.voice = voice
            }
            self.synthesizer.speak(utterance)
            self.isSpeaking = true
            self.updateReadAloudButton()
        }
    }

    private func stopReadAloud() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        updateReadAloudButton()
    }

    private func updateReadAloudButton() {
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            readAloudItem?.image = UIImage(systemName: "pause.circle")
            readAloudItem?.accessibilityLabel = L10n.RSS.stopReadAloud
        } else {
            readAloudItem?.image = UIImage(systemName: "play.circle")
            readAloudItem?.accessibilityLabel = L10n.RSS.readAloud
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        updateReadAloudButton()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        updateReadAloudButton()
    }

    // MARK: - 收藏

    @objc private func toggleFavorite() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let nowFavorite = try await self.screen.toggleFavorite(article: self.article)
                await MainActor.run {
                    self.isFavorite = nowFavorite
                    let favoriteItem = self.navigationItem.rightBarButtonItems?.first(where: {
                        $0.accessibilityIdentifier == UIIdentifiers.RSS.articleFavoriteButton
                    }) ?? self.navigationItem.rightBarButtonItem
                    favoriteItem?.title = nowFavorite ? L10n.RSS.unmarkFavorite : L10n.RSS.markFavorite
                }
            } catch {
                await MainActor.run {
                    self.presentError(error)
                }
            }
        }
    }
}
