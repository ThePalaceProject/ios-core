//
//  NSNotification+NYPL.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceNetwork
import PalacePreferences
import PalaceBookRegistry

extension Notification.Name {
    static let TPPUserAccountDidChange = Notification.Name("TPPUserAccountDidChangeNotification")
    static let TPPDidSignOut = Notification.Name("TPPDidSignOut")
    static let TPPAppDelegateDidReceiveCleverRedirectURL = Notification.Name("TPPAppDelegateDidReceiveCleverRedirectURL")
    // Registry sync and change events are the registry's Combine publishers
    // (syncEventPublisher / registryDidChangePublisher / bookStatePublisher /
    // registryStatePublisher / holdsDidChangePublisher), not notifications.
    // Current-library changes, catalog loads and sign-in progress are
    // `AccountsManager`'s `currentLibraryChangePublisher`,
    // `catalogLoadedPublisher` and `signInProgressPublisher`.

    /// The `userInfo` dictionary contains the following key-value pairs:
    /// - an `bookProcessingBookIDKey` key whose value is a String indicating
    /// the book identifier;
    /// - a `bookProcessingValueKey` key whose value is a Bool indicating
    /// if there's some processing going on for the book.
    static let TPPBookProcessingDidChange = Notification.Name("TPPBookProcessingDidChange")

    static let TPPMyBooksDownloadCenterDidChange = Notification.Name("TPPMyBooksDownloadCenterDidChange")
    // TPPReachabilityChanged is defined in PalaceNetwork; do not duplicate.
}

@objc extension NSNotification {
    public static let TPPSettingsDidChange = Notification.Name.TPPSettingsDidChange
    public static let TPPUseBetaDidChange = Notification.Name.TPPUseBetaDidChange
    public static let TPPUserAccountDidChange = Notification.Name.TPPUserAccountDidChange
    public static let TPPDidSignOut = Notification.Name.TPPDidSignOut
    public static let TPPAppDelegateDidReceiveCleverRedirectURL = Notification.Name.TPPAppDelegateDidReceiveCleverRedirectURL
    public static let TPPBookProcessingDidChange = Notification.Name.TPPBookProcessingDidChange
    public static let TPPMyBooksDownloadCenterDidChange = Notification.Name.TPPMyBooksDownloadCenterDidChange
    public static let TPPReachabilityChanged = Notification.Name.TPPReachabilityChanged
}

class TPPNotificationKeys: NSObject {
    @objc public static let bookProcessingBookIDKey = "identifier"
    @objc public static let bookProcessingValueKey = "value"
}
