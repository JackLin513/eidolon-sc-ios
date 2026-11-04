import SwiftUI
import UIKit

/// Puts the tab bar away while a page owns the whole screen, and brings it back when that
/// page goes away.
///
/// The SwiftUI route (`.toolbar(.hidden, for: .tabBar)` on the pushed page) does hide the
/// bar, but with the iOS 26 floating tab bar it does not reliably bring it back when the
/// page is popped (spec #64). The UIKit property is set by the page itself, so leaving the
/// page always restores the bar.
struct TabBarHides: UIViewControllerRepresentable {
    /// False while a call is live: the call bar promises that the other tabs stay within
    /// reach, and the player may still draw or reset a card from the play tab (spec #64).
    var hidden: Bool = true

    func makeUIViewController(context: Context) -> Controller { Controller(hidden: hidden) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hidden = hidden
    }

    final class Controller: UIViewController {
        var hidden: Bool {
            didSet {
                // SwiftUI updates a disappearing page once more; that must not put the
                // bar back down after the page already handed it back.
                guard hidden != oldValue, viewIfLoaded?.window != nil else { return }
                setBarHidden(hidden)
            }
        }

        init(hidden: Bool) {
            self.hidden = hidden
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            setBarHidden(parent == nil ? false : hidden)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            setBarHidden(hidden)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setBarHidden(false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // The controller may appear before the tab bar controller is its parent; by
            // now it is, so the state set on the way up can be applied for real.
            setBarHidden(hidden)
        }

        private func setBarHidden(_ hidden: Bool) {
            guard let tabBarController else {
                // Not attached yet: try once after the next layout pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let tabBarController = self.tabBarController else { return }
                    tabBarController.setTabBarHidden(hidden, animated: true)
                }
                return
            }
            tabBarController.setTabBarHidden(hidden, animated: true)
        }
    }
}
