import UIKit

/// A screen may consume a native back swipe before UIKit starts popping its controller.
protocol NavigationBackActionHandling: AnyObject {
    func interceptNavigationBackGesture() -> Bool
}
