//
//  Account+profileDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

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
        AppContainer.production().networkExecutor.executeRequest(request.applyCustomUserAgent(), enableTokenRefresh: false) { result in
            switch result {
            case .success(let data, _):
                do {
                    let profileDocument = try UserProfileDocument.fromData(data)
                    DispatchQueue.main.async {
                        completion(profileDocument)
                    }
                    return
                } catch {
                    TPPErrorLogger.logError(error, summary: "Error parsing user profile document")
                }
            case .failure(let error, _):
                TPPErrorLogger.logError(error, summary: "Error retrieveing user profile document")
            }
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }

}
