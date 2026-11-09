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
    // Registry sync and change events are the registry's Combine publishers
    // (syncEventPublisher / registryDidChangePublisher / bookStatePublisher /
    // registryStatePublisher / holdsDidChangePublisher), not notifications.
    // Current-library changes, catalog loads and sign-in progress are
    // `AccountsManager`'s `currentLibraryChangePublisher`,
    // `catalogLoadedPublisher` and `signInProgressPublisher`.
    // A book's processing flag is `TPPBookRegistry.bookProcessingPublisher`.

    // TPPReachabilityChanged is defined in PalaceNetwork; do not duplicate.
}

@objc extension NSNotification {
    public static let TPPSettingsDidChange = Notification.Name.TPPSettingsDidChange
    public static let TPPUseBetaDidChange = Notification.Name.TPPUseBetaDidChange
    public static let TPPReachabilityChanged = Notification.Name.TPPReachabilityChanged
}
