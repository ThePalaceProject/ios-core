//
//  TPPAppDelegate+Extensions.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension TPPAppDelegate {
  @objc func topViewController(_ viewController: UIViewController? = nil) -> UIViewController? {
    if let viewController { return traverseTop(from: viewController) }

    // Prefer active foreground scene, then fallback to keyWindow on older APIs
    if let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
       let keyWin = scene.windows.first(where: { $0.isKeyWindow }),
       let root = keyWin.rootViewController {
      return traverseTop(from: root)
    }

    if let win = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
       let root = win.rootViewController {
      return traverseTop(from: root)
    }
    return nil
  }

  private func traverseTop(from controller: UIViewController?) -> UIViewController? {
    guard let controller else { return nil }
    if let nav = controller as? UINavigationController { return traverseTop(from: nav.visibleViewController) }
    if let tab = controller as? UITabBarController, let selected = tab.selectedViewController { return traverseTop(from: selected) }
    if let presented = controller.presentedViewController { return traverseTop(from: presented) }
    return controller
  }
}
