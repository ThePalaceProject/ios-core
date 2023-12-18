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
    TPPNetworkExecutor.shared.executeRequest(URLRequest(url: profileUrl), useTokenIfAvailable: false) { result in
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
