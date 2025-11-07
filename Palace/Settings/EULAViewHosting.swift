//
//  EULAViewHosting.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// Bridge class to create EULAView from Objective-C
@objcMembers
class EULAViewHosting: NSObject {
  
  /// Creates a UIHostingController with EULAView for the given account
  static func makeEULAView(account: Account) -> UIViewController {
    let view = EULAView(account: account)
    let controller = UIHostingController(rootView: view)
    return controller
  }
  
  /// Creates a UIHostingController with EULAView using NYPL URL
  static func makeEULAViewWithNYPLURL() -> UIViewController {
    let view = EULAView(nyplURL: true)
    let controller = UIHostingController(rootView: view)
    return controller
  }
}

