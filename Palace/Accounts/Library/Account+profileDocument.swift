//
//  Account+profileDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

extension Account {

    func getProfileDocument(completion: @escaping (_ profileDocument: UserProfileDocument?) -> Void) {
        guard let profileHref = self.details?.userProfileUrl,
              let profileUrl = URL(string: profileHref)
        else {
            // Can be a normal situation, no active user account
            completion(nil)
            return
        }

        // The user-profile endpoint is authenticated; without credentials it
        // returns 401 with an OPDS auth-document body. Anonymous libraries
        // (Palace Bookshelf / DPLA) advertise a `userProfileUrl` in their
        // auth document but no app surface needs the result for an anonymous
        // user. Skip when no credentials are stored — chaos-qa dogfood-5
        // surfaced that NotificationService.updateToken() and deleteToken(for:)
        // call this on every account-change rehydration, producing a
        // /patrons/me/ 401 storm at every cold relaunch (PP-4164 → F-007 →
        // refined by F-DG5-002).
        let userAccount = TPPUserAccount.sharedAccount(libraryUUID: self.uuid)
        if !userAccount.hasCredentials() {
            completion(nil)
            return
        }

        var request = URLRequest(url: profileUrl)
        // PP-4986: this is `self.uuid`'s profile, fetched with that library's
        // credentials — and `getProfileDocument` is called for non-current
        // libraries (LibrariesSectionViewModel). Naming the account keeps a 401
        // retry authenticating as this library rather than the selected one.
        AppContainer.production().networkExecutor.executeRequest(request.applyCustomUserAgent(), enableTokenRefresh: false, accountId: self.uuid) { result in
            // The executeRequest completion is a plain (non-Sendable) escaping
            // closure, so `completion` and the parsed `UserProfileDocument`
            // are captured safely here. They are carried across the main-queue
            // hop in a documented box — touched only on that single main-queue
            // block, never concurrently — to satisfy the `@Sendable`
            // `DispatchQueue.main.async`.
            switch result {
            case .success(let data, _):
                do {
                    let profileDocument = try UserProfileDocument.fromData(data)
                    let box = ProfileDocumentCompletionBox(completion: completion, document: profileDocument)
                    DispatchQueue.main.async {
                        box.completion(box.document)
                    }
                    return
                } catch {
                    self.errorReporter.report(error, summary: "Error parsing user profile document")
                }
            case .failure(let error, _):
                self.errorReporter.report(error, summary: "Error retrieveing user profile document")
            }
            let box = ProfileDocumentCompletionBox(completion: completion, document: nil)
            DispatchQueue.main.async {
                box.completion(box.document)
            }
        }
    }

}

/// Documented carrier for `getProfileDocument`'s network completion, which
/// hops to the main queue to invoke `completion` with the parsed document.
/// The `completion` closure and `UserProfileDocument` are non-Sendable;
/// they are only ever read on that single main-queue hop, never
/// concurrently, so they are safe to carry in an `@unchecked Sendable` box.
private struct ProfileDocumentCompletionBox: @unchecked Sendable {
    let completion: (UserProfileDocument?) -> Void
    let document: UserProfileDocument?
}
