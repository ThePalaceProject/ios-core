//
//  TPPSettingsSplitViewController.swift
//  The Palace Project / Open eBooks
//
//  Created by Kyle Sakai.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

/// Currently used only by Open eBooks, but extendable for use in SimplyE.
/// - Seealso: https://github.com/NYPL-Simplified/Simplified-iOS/pull/1070
/// TODO: SIMPLY-3053
class TPPSettingsSplitViewController : UISplitViewController, UISplitViewControllerDelegate {
  private var isFirstLoad: Bool
  private var currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider
  
  @objc init(currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider) {
    self.isFirstLoad = true
    self.currentLibraryAccountProvider = currentLibraryAccountProvider
    let navVC = UINavigationController.init(rootViewController: TPPSettingsPrimaryTableViewController())
    super.init(nibName: nil, bundle: nil)
    
    self.delegate = self
    self.title = DisplayStrings.Settings.settings
    self.tabBarItem.image = UIImage.init(named: "Settings")
    self.viewControllers = [navVC]
    self.presentsWithGesture = false
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  var primaryTableVC: TPPSettingsPrimaryTableViewController? {
    let navVC = self.viewControllers.first as? UINavigationController
    return navVC?.viewControllers.first as? TPPSettingsPrimaryTableViewController
  }

  // MARK: UIViewController

  override func viewDidLoad() {
    super.viewDidLoad()
    self.preferredDisplayMode = .allVisible

    configPrimaryVCItems(using:
      TPPLibraryAccountURLsProvider(account:
        currentLibraryAccountProvider.currentAccount))
  }
  
  // MARK: UISplitViewControllerDelegate

  func splitViewController(_ splitVC: UISplitViewController,
                           collapseSecondary secondaryVC: UIViewController,
                           onto primaryVC: UIViewController) -> Bool {
    let rVal = self.isFirstLoad
    self.isFirstLoad = false
    return rVal
  }
}
