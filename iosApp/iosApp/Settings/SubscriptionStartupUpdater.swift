import shared
import UIKit

/// Runs once per app launch after shared bootstrap; only subscriptions explicitly marked for updates.
@MainActor
final class SubscriptionStartupUpdater {
    static let shared = SubscriptionStartupUpdater()
    private var started = false

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            do {
                let facade = try BootstrapApiKt.sharedBackupCapabilitiesFacade()
                let subscriptions: [RuleSub] = try await SharedAsync.value { facade.loadSubscriptions(completionHandler: $0) }
                for item in subscriptions where item.autoUpdate {
                    do {
                        let _: KotlinInt = try await SharedAsync.value { facade.updateSubscription(id: item.id, completionHandler: $0) }
                    } catch {
                        // Do not expose request URLs, authentication, or headers in startup feedback.
                        SharedRuntime.log("源订阅自动更新失败，类型：\(item.type)，请在订阅与服务页面重试")
                    }
                }
            } catch {
                started = false
            }
        }
    }
}
