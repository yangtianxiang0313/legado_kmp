import UIKit
import shared

/// Certificate errors offer an explicit, revocable exception; ordinary errors never change trust.
@MainActor
enum SourceNetworkCertificatePrompt {
    private static var observer: NSObjectProtocol?
    private static var banner: UIView?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("io.legado.source-network.certificate-rejected"), object: nil, queue: .main
        ) { notification in
            let id = notification.userInfo?["issueId"] as? String
            Task { @MainActor in
                guard let issue = SourceNetworkPolicy.shared.issues(sourceUrl: nil).first(where: { $0.id == id }) else { return }
                show(issue)
            }
        }
    }

    private static func currentWindow() -> UIWindow? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            .first { $0.isKeyWindow && !$0.isHidden && AppLockManager.shared.isUnlocked(in: $0) }
    }

    private static func show(_ issue: SourceCertificateIssue) {
        guard let window = currentWindow() else { return }
        banner?.removeFromSuperview()
        let notice = UIView()
        notice.backgroundColor = AndroidReplicaTheme.menuBackground
        notice.layer.cornerRadius = 8
        notice.layer.borderWidth = 1
        notice.layer.borderColor = AndroidReplicaTheme.divider.cgColor
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.accessibilityIdentifier = "source.network.certificate.notice"
        let label = UILabel()
        label.text = SourceNetworkCopy.text("certificate_failed", "书源证书校验失败") + "\n" + issue.host
        label.textColor = AndroidReplicaTheme.primaryText
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        let action = UIButton(type: .system)
        action.setTitle(SourceNetworkCopy.text("compatibility", "证书兼容"), for: .normal)
        action.accessibilityIdentifier = "source.network.certificate.allow"
        action.addAction(
            UIAction { [weak window, weak notice] _ in
                guard let window, currentWindow() === window, let root = window.rootViewController else { return }
                let presenter = root.topmostPresentedViewController
                guard !(presenter is UIAlertController), presenter.presentedViewController == nil else { return }
                notice?.removeFromSuperview()
                confirm(issue, in: presenter)
            }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = L10n.Common.close
        close.addAction(UIAction { [weak notice] _ in notice?.removeFromSuperview() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [label, action, close])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        notice.addSubview(row)
        window.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            row.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: notice.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -8),
            action.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak notice] in notice?.removeFromSuperview() }
    }

    static func confirm(_ issue: SourceCertificateIssue, in presenter: UIViewController, onChanged: (() -> Void)? = nil) {
        guard presenter.viewIfLoaded?.window === currentWindow(), presenter.presentedViewController == nil,
            SourceNetworkPolicy.shared.issues(sourceUrl: issue.sourceUrl).contains(where: { $0.id == issue.id })
        else { return }
        let message = String(
            format: SourceNetworkCopy.text(
                "certificate_warning",
                "书源：%@\n服务器：%@:%d\n证书 SHA-256：%@\n\n此服务器的身份无法通过系统验证，可能存在冒充风险。授权只适用于此书源的这个域名及证书，30 天后过期；其他域名、登录、上传与云备份不受影响。"),
            issue.sourceUrl, issue.host, issue.port, issue.fingerprint)
        let alert = UIAlertController(
            title: SourceNetworkCopy.text("certificate_failed", "书源证书校验失败"), message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "source.network.certificate.confirm"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: SourceNetworkCopy.text("allow_action", "允许此书源证书兼容"), style: .destructive) { [weak presenter] _ in
                guard let presenter, presenter.viewIfLoaded?.window === currentWindow() else { return }
                do {
                    try SourceNetworkPolicy.shared.allowCertificate(issueId: issue.id)
                    presenter.showTransientMessage(SourceNetworkCopy.text("allowed", "已允许此域名及证书，请重试原操作"))
                    onChanged?()
                } catch { presenter.showTransientMessage(error.userFacingMessage) }
            })
        presenter.present(alert, animated: true)
    }
}
