//
//  NYPLSettingsPrimaryTableItem.swift
//  SimplyE / Open eBooks
//
//  Created by Kyle Sakai.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

class NYPLSettingsPrimaryTableItem {
  let path: IndexPath
  let name: String
  fileprivate let vc: UIViewController?
  fileprivate let handler: ((UISplitViewController, UITableViewController)->())?
  
  init(indexPath: IndexPath, title: String, viewController: UIViewController) {
    path = indexPath
    name = title
    vc = viewController
    handler = nil
  }
  
  init(indexPath: IndexPath, title: String, selectionHandler: @escaping (UISplitViewController, UITableViewController)->()) {
    path = indexPath
    name = title
    vc = nil
    handler = selectionHandler
  }
  
  func handleItemTouched(splitVC: UISplitViewController, tableVC: UITableViewController) {
    if vc != nil {
      splitVC.showDetailViewController(vc!, sender: nil)
    } else if handler != nil {
      handler!(splitVC, tableVC)
    }
  }
  
  class func handleVCWrap(_ vc: UIViewController) -> UIViewController {
    if UIDevice.current.userInterfaceIdiom == .pad {
      return UINavigationController(rootViewController: vc)
    }
    return vc
  }
  
  class func generateRemoteView(title: String, url: String) -> UIViewController {
    let remoteView = RemoteHTMLViewController.init(
      URL: URL.init(string: url)!,
      title: title,
      failureMessage: NSLocalizedString("SettingsConnectionFailureMessage", comment: "")
    )
    return handleVCWrap(remoteView)
  }
}
