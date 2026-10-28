import UIKit

final class BookshelfRootView: UIView {
    let contentContainer = UIView()
    private let headers = UIStackView()
    private let toolbarBackdrop = UIView()
    private let tabHeader: AndroidBookshelfHeaderView
    private let folderHeader: UIView?

    init(header: AndroidBookshelfHeaderView, folderHeader: UIView? = nil) {
        tabHeader = header
        self.folderHeader = folderHeader
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background

        toolbarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        toolbarBackdrop.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbarBackdrop.isUserInteractionEnabled = false
        toolbarBackdrop.accessibilityElementsHidden = true
        addSubview(toolbarBackdrop)
        headers.axis = .vertical
        headers.translatesAutoresizingMaskIntoConstraints = false
        headers.addArrangedSubview(header)
        if let folderHeader {
            headers.addArrangedSubview(folderHeader)
            folderHeader.isHidden = true
        }
        addSubview(headers)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            toolbarBackdrop.topAnchor.constraint(equalTo: topAnchor),
            toolbarBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBackdrop.bottomAnchor.constraint(equalTo: headers.bottomAnchor),
            headers.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            headers.leadingAnchor.constraint(equalTo: leadingAnchor),
            headers.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headers.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshColors()
    }

    func refreshColors() {
        backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        toolbarBackdrop.backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        tabHeader.refreshColors()
        (folderHeader as? BookshelfFolderHeaderView)?.refreshColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true {
            refreshColors()
        }
    }

    func setFolderMode(_ enabled: Bool) {
        tabHeader.isHidden = enabled && folderHeader != nil
        folderHeader?.isHidden = !enabled
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    static func statusBarStyle(for traits: UITraitCollection) -> UIStatusBarStyle {
        let text = AndroidReplicaTheme.toolbarText.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard text.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return .lightContent }
        return red * 0.299 + green * 0.587 + blue * 0.114 > 0.5 ? .lightContent : .darkContent
    }
}
