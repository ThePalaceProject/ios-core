//
//  NSNotification+NYPL.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension Notification.Name {
  static let TPPSettingsDidChange = Notification.Name("TPPSettingsDidChange")
  static let TPPCurrentAccountDidChange = Notification.Name("TPPCurrentAccountDidChange")
  static let TPPCatalogDidLoad = Notification.Name("TPPCatalogDidLoad")
  static let TPPSyncBegan = Notification.Name("TPPSyncBegan")
  static let TPPSyncEnded = Notification.Name("TPPSyncEnded")
  static let TPPUseBetaDidChange = Notification.Name("TPPUseBetaDidChange")
  static let TPPUserAccountDidChange = Notification.Name("TPPUserAccountDidChangeNotification")
  static let TPPDidSignOut = Notification.Name("TPPDidSignOut")
  static let TPPIsSigningIn = Notification.Name("TPPIsSigningIn")
  static let TPPAppDelegateDidReceiveCleverRedirectURL = Notification.Name("TPPAppDelegateDidReceiveCleverRedirectURL")
  static let TPPBookRegistryDidChange = Notification.Name("TPPBookRegistryDidChange")
  static let TPPBookRegistryStateDidChange = Notification.Name("TPPBookRegistryStateDidChange")

  /// The `userInfo` dictionary contains the following key-value pairs:
  /// - an `bookProcessingBookIDKey` key whose value is a String indicating
  /// the book identifier;
  /// - a `bookProcessingValueKey` key whose value is a Bool indicating
  /// if there's some processing going on for the book.
  static let TPPBookProcessingDidChange = Notification.Name("TPPBookProcessingDidChange")

  static let TPPMyBooksDownloadCenterDidChange = Notification.Name("TPPMyBooksDownloadCenterDidChange")
  static let TPPBookDetailDidClose = Notification.Name("TPPBookDetailDidClose")
  static let TPPAccountSetDidLoad = Notification.Name("TPPAccountSetDidLoad")
  static let TPPReachabilityChanged = Notification.Name("TPPReachabilityChanged")
}

@objc extension NSNotification {
  public static let TPPSettingsDidChange = Notification.Name.TPPSettingsDidChange
  public static let TPPCurrentAccountDidChange = Notification.Name.TPPCurrentAccountDidChange
  public static let TPPCatalogDidLoad = Notification.Name.TPPCatalogDidLoad
  public static let TPPSyncBegan = Notification.Name.TPPSyncBegan
  public static let TPPSyncEnded = Notification.Name.TPPSyncEnded
  public static let TPPUseBetaDidChange = Notification.Name.TPPUseBetaDidChange
  public static let TPPUserAccountDidChange = Notification.Name.TPPUserAccountDidChange
  public static let TPPDidSignOut = Notification.Name.TPPDidSignOut
  public static let TPPIsSigningIn = Notification.Name.TPPIsSigningIn
  public static let TPPAppDelegateDidReceiveCleverRedirectURL = Notification.Name.TPPAppDelegateDidReceiveCleverRedirectURL
  public static let TPPBookRegistryDidChange = Notification.Name.TPPBookRegistryDidChange
  public static let TPPBookRegistryStateDidChange = Notification.Name.TPPBookRegistryStateDidChange
  public static let TPPBookProcessingDidChange = Notification.Name.TPPBookProcessingDidChange
  public static let TPPMyBooksDownloadCenterDidChange = Notification.Name.TPPMyBooksDownloadCenterDidChange
  public static let TPPBookDetailDidClose = Notification.Name.TPPBookDetailDidClose
  public static let TPPAccountSetDidLoad = Notification.Name.TPPAccountSetDidLoad
  public static let TPPReachabilityChanged = Notification.Name.TPPReachabilityChanged
}

class TPPNotificationKeys: NSObject {
  @objc public static let bookProcessingBookIDKey = "identifier"
  @objc public static let bookProcessingValueKey = "value"
}
