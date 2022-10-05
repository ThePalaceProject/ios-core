//
//  TPPSettingsPrimaryTableItem.swift
//  The Palace Project / Open eBooks
//
//  Created by Kyle Sakai.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

class TPPSettingsPrimaryTableItem {
  let path: IndexPath
  let name: String
  private let vc: UIViewController?
  private let handler: ((UISplitViewController, UITableViewController)->())?
  
  init(indexPath: IndexPath,
       title: String,
       viewController: UIViewController? = nil,
       selectionHandler: ((UISplitViewController, UITableViewController)->())? = nil) {
    
    path = indexPath
    name = title
    vc = viewController
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
  
  class func generateRemoteView(title: String, url: URL) -> UIViewController {
    let remoteView = RemoteHTMLViewController.init(
      URL: url,
      title: title,
      failureMessage: DisplayStrings.Error.pageLoadFailedError
    )
    return handleVCWrap(remoteView)
  }
}
