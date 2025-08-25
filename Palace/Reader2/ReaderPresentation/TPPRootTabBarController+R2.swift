
//
//  TPPRootTabBarController+R2.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/4/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

@objc extension TPPRootTabBarController {
  func presentBook(_ book: TPPBook) {
    guard let libraryService = r3Owner?.libraryService, let readerModule = r3Owner?.readerModule else {
      return
    }
    
    libraryService.openBook(book, sender: self) { [weak self] result in
      guard let navVC = self?.selectedViewController as? UINavigationController else {
        preconditionFailure("No navigation controller, unable to present reader")
      }
      switch result {
      case .success(let publication):
        self?.hideFloatingTabBarIfNeeded()
        readerModule.presentPublication(publication, book: book, in: navVC, forSample: false)
      case .failure(let error):
        self?.restoreFloatingTabBar()

        // .failure is retured for an error raised while trying to unlock publication
        // error is supposed to be visible to users, it is defined by ContentProtection error property
        TPPErrorLogger.logError(error, summary: "Error accessing book resources", metadata: [
          "book": book.loggableDictionary
        ])
        let alertController = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: self, animated: true, completion: nil)
      }
    }
  }
  
  private func hideFloatingTabBarIfNeeded() {
    UITabBarController.hideFloatingTabBar()
  }
  
  @objc private func restoreFloatingTabBar() {
    UITabBarController.showFloatingTabBar()
  }

  func presentSample(_ book: TPPBook, url: URL) {
    guard !isPresentingSample else {
      return
    }
    
    isPresentingSample = true
    
    defer {
      isPresentingSample = false
    }

    guard let libraryService = r3Owner?.libraryService, let readerModule = r3Owner?.readerModule else {
      return
    }
    
    libraryService.openSample(book, sampleURL: url, sender: self) { [weak self] result in
      guard let navVC = self?.selectedViewController as? UINavigationController else {
        preconditionFailure("No navigation controller, unable to present reader")
      }
      switch result {
      case .success(let publication):
        readerModule.presentPublication(publication, book: book, in: navVC, forSample: true)
      case .failure(let error):
        // .failure is retured for an error raised while trying to unlock publication
        // error is supposed to be visible to users, it is defined by ContentProtection error property
        TPPErrorLogger.logError(error, summary: "Error accessing book resources", metadata: [
          "book": book.loggableDictionary
        ])
        let alertController = TPPAlertUtils.alert(title: "Content Protection Error", message: error.localizedDescription)
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: self, animated: true, completion: nil)
      }
    }
  }
}

//import UIKit

extension UITabBarController {
  private static func findTabBarController(in vc: UIViewController) -> UITabBarController? {
    if let tbc = vc as? UITabBarController { return tbc }
    if let nav = vc as? UINavigationController {
      return nav.viewControllers.first.flatMap(findTabBarController)
    }
    if let presented = vc.presentedViewController {
      return findTabBarController(in: presented)
    }
    return nil
  }

  private static func root() -> UITabBarController? {
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      if let win = scene.windows.first(where: \.isKeyWindow),
         let root = win.rootViewController,
         let tbc  = findTabBarController(in: root) {
        return tbc
      }
    }
    if let win = UIApplication.shared.windows.first(where: \.isKeyWindow),
       let root = win.rootViewController
    {
      return findTabBarController(in: root)
    }
    return nil
  }

  @objc static func hideFloatingTabBar(animated: Bool = false) {
    guard UIDevice.current.userInterfaceIdiom == .pad,
          let tbc = root()
    else { return }
    
    let sel = NSSelectorFromString("setTabBarHidden:animated:")
    DispatchQueue.main.async {
      if tbc.responds(to: sel) {
        let imp = tbc.method(for: sel)!
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(tbc, sel, true, animated)
      } else {
        let duration = animated ? 0.25 : 0
        UIView.animate(withDuration: duration) {
          tbc.tabBar.alpha = 0
        } completion: { _ in
          tbc.tabBar.isHidden = true
        }
      }
    }
  }
  
  @objc static func showFloatingTabBar(animated: Bool = true) {
    guard UIDevice.current.userInterfaceIdiom == .pad,
          let tbc = root()
    else { return }
    
    let sel = NSSelectorFromString("setTabBarHidden:animated:")
    DispatchQueue.main.async {
      if tbc.responds(to: sel) {
        let imp = tbc.method(for: sel)!
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(tbc, sel, false, animated)
      } else {
        tbc.tabBar.isHidden = false
        let duration = animated ? 0.25 : 0
        UIView.animate(withDuration: duration) {
          tbc.tabBar.alpha = 1
        }
      }
    }
  }
}
