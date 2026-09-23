//
//  TPPBook+Additions.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceBookModel

extension TPPBook {
    // TODO: SIMPLY-2656 Remove this hack if possible, or at least use DI for
    // instead of implicitly using NYPLMyBooksDownloadCenter
    /// Legacy computed property for file URL. Prefer `fileUrl(downloadCenter:)` for testability.
    var url: URL? {
        return AppContainer.production().downloadCenter.fileUrl(for: identifier)
    }

    /// Whether returning or deleting this title requires an authenticated user.
    /// Reaches `AppContainer.production()` for the accounts graph, so it stays
    /// app-side (Wave 2a: the model package must not depend on Accounts/DI).
    func requiresAuthForReturnOrDeletion() -> Bool {
        let userAuthRequired = AppContainer.production().accountsManager.currentUserAccount.authDefinition?.needsAuth ?? false
        return self.defaultAcquisitionIfOpenAccess == nil && userAuthRequired
    }
}
