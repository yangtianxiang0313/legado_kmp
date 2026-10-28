import UIKit
import shared

final class ReplaceRuleViewController: UIViewController {
    private let replicaController = AndroidReplicaReplaceRuleViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(replicaController)
        view.addSubview(replicaController.view)
        replicaController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replicaController.view.topAnchor.constraint(equalTo: view.topAnchor),
            replicaController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            replicaController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            replicaController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        replicaController.didMove(toParent: self)
    }
}

// MARK: - ReplaceRuleScreenAdapter

final class ReplaceRuleScreenAdapter {
    private let bindings = ScreenBindingController(owner: "ReplaceRuleScreen")
    private(set) var facade: ReplaceRuleFacade?

    var onRulesChange: (([ReplaceRule]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()

        switch SharedRuntime.replaceRuleFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(
                facade.watchRules { [weak self] rules in
                    DispatchQueue.main.async {
                        self?.onRulesChange?(rules)
                    }
                })
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func toggleEnabled(id: Int64) async throws {
        guard let facade else { return }
        try await facade.toggleEnabledAsync(id: id)
    }

    func deleteRule(id: Int64) async throws {
        guard let facade else { return }
        try await facade.deleteRuleAsync(id: id)
    }

    func updateOrder(id: Int64, order: Int32) async throws {
        guard let facade else { return }
        try await facade.updateOrderAsync(id: id, order: order)
    }

    func updateEnabled(id: Int64, enabled: Bool) async throws {
        guard let facade else { return }
        try await facade.updateEnabledAsync(id: id, enabled: enabled)
    }

    func deleteRules(_ rules: [ReplaceRule]) async throws {
        guard let facade else { return }
        try await facade.deleteRulesAsync(rules: rules)
    }

    func saveRule(_ rule: ReplaceRule) async throws {
        guard let facade else { return }
        _ = try await facade.saveRuleAsync(rule: rule)
    }

    func saveRules(_ rules: [ReplaceRule]) async throws {
        guard let facade else { return }
        try await facade.saveRulesAsync(rules: rules)
    }
}
