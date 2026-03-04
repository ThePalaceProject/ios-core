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

        if let keyWin = UIApplication.shared.mainKeyWindow,
           let root = keyWin.rootViewController {
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
