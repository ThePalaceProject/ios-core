//
//  TPPAppDelegate+Extensions.swift
//  Palace
//
//  Created by Vladimir Fedorov on 23/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension TPPAppDelegate {
  func topViewController(_ viewController: UIViewController? = nil) -> UIViewController? {
    guard let controller = viewController ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      return nil
    }
    
    if let navigationController = controller as? UINavigationController {
      return topViewController(navigationController.visibleViewController)
    }
    if let tabController = controller as? UITabBarController {
      if let selected = tabController.selectedViewController {
        return topViewController(selected)
      }
    }
    if let presented = controller.presentedViewController {
      return topViewController(presented)
    }
    return controller
  }
}
