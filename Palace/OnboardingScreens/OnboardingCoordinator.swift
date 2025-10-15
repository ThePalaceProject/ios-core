import UIKit
import SwiftUI

final class OnboardingCoordinator {
  static let shared = OnboardingCoordinator()
  private init() {}

  func startIfNeeded(from appDelegate: TPPAppDelegate) {
    guard shouldRunOnboarding else { return }
    presentOnboarding(from: appDelegate) { [weak self, weak appDelegate] in
      guard let self, let appDelegate else { return }
      self.presentAccountList(from: appDelegate)
      TPPSettings.shared.userHasSeenWelcomeScreen = true
    }
  }

  private var shouldRunOnboarding: Bool {
    let hasSeen = TPPSettings.shared.userHasSeenWelcomeScreen
    let hasAccount = AccountsManager.shared.currentAccount != nil
    return !hasSeen || !hasAccount
  }

  private func presentOnboarding(from appDelegate: TPPAppDelegate, completion: @escaping () -> Void) {
    let vc = TPPOnboardingViewController.makeSwiftUIView(dismissHandler: completion)
    guard let top = appDelegate.topViewController() else { return }
    top.present(vc, animated: true)
  }

  private func presentAccountList(from appDelegate: TPPAppDelegate) {
    let presentList: () -> Void = { [weak appDelegate] in
      guard let top = appDelegate?.topViewController() else { return }
      let accountList = TPPAccountList { account in
        MyBooksViewModel().authenticateAndLoad(account: account)
      }
      let nav = UINavigationController(rootViewController: accountList)
      top.present(nav, animated: true)
    }

    if AccountsManager.shared.accountsHaveLoaded {
      presentList()
    } else {
      NotificationCenter.default.addObserver(forName: .TPPCatalogDidLoad, object: nil, queue: .main) { _ in
        presentList()
      }
      AccountsManager.shared.loadCatalogs(completion: nil)
    }
  }
}


