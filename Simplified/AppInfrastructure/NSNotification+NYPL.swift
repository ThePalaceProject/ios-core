//
//  NSNotification+NYPL.swift
//  Simplified
//
//  Created by Ettore Pasquini on 9/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension Notification.Name {
  static let NYPLSettingsDidChange = Notification.Name("NYPLSettingsDidChange")
  static let NYPLCurrentAccountDidChange = Notification.Name("NYPLCurrentAccountDidChange")
  static let NYPLCatalogDidLoad = Notification.Name("NYPLCatalogDidLoad")
  static let NYPLSyncBegan = Notification.Name("NYPLSyncBegan")
  static let NYPLSyncEnded = Notification.Name("NYPLSyncEnded")
  static let NYPLUseBetaDidChange = Notification.Name("NYPLUseBetaDidChange")
  static let NYPLUserAccountDidChange = Notification.Name("NYPLUserAccountDidChangeNotification")
  static let NYPLDidSignOut = Notification.Name("NYPLDidSignOut")
  static let NYPLIsSigningIn = Notification.Name("NYPLIsSigningIn")
  static let NYPLAppDelegateDidReceiveCleverRedirectURL = Notification.Name("NYPLAppDelegateDidReceiveCleverRedirectURL")
  static let NYPLBookRegistryDidChange = Notification.Name("NYPLBookRegistryDidChange")
  static let NYPLBookProcessingDidChange = Notification.Name("NYPLBookProcessingDidChange")
  static let NYPLMyBooksDownloadCenterDidChange = Notification.Name("NYPLMyBooksDownloadCenterDidChange")
  static let NYPLBookDetailDidClose = Notification.Name("NYPLBookDetailDidClose")
}

@objc extension NSNotification {
  public static let NYPLSettingsDidChange = Notification.Name.NYPLSettingsDidChange
  public static let NYPLCurrentAccountDidChange = Notification.Name.NYPLCurrentAccountDidChange
  public static let NYPLCatalogDidLoad = Notification.Name.NYPLCatalogDidLoad
  public static let NYPLSyncBegan = Notification.Name.NYPLSyncBegan
  public static let NYPLSyncEnded = Notification.Name.NYPLSyncEnded
  public static let NYPLUseBetaDidChange = Notification.Name.NYPLUseBetaDidChange
  public static let NYPLUserAccountDidChange = Notification.Name.NYPLUserAccountDidChange
  public static let NYPLDidSignOut = Notification.Name.NYPLDidSignOut
  public static let NYPLIsSigningIn = Notification.Name.NYPLIsSigningIn
  public static let NYPLAppDelegateDidReceiveCleverRedirectURL = Notification.Name.NYPLAppDelegateDidReceiveCleverRedirectURL
  public static let NYPLBookRegistryDidChange = Notification.Name.NYPLBookRegistryDidChange
  public static let NYPLBookProcessingDidChange = Notification.Name.NYPLBookProcessingDidChange
  public static let NYPLMyBooksDownloadCenterDidChange = Notification.Name.NYPLMyBooksDownloadCenterDidChange
  public static let NYPLBookDetailDidClose = Notification.Name.NYPLBookDetailDidClose
}
