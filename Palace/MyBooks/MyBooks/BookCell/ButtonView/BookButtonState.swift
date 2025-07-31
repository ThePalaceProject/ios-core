//
//  BookButtonState.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

enum BookButtonState {
  case canBorrow
  case canHold
  case holding
  case holdingFrontOfQueue
  case downloadNeeded
  case downloadSuccessful
  case used
  case downloadInProgress
  case returning
  case managingHold
  case downloadFailed
  case unsupported
}

extension BookButtonState {
  func buttonTypes(book: TPPBook, previewEnabled: Bool = true) -> [BookButtonType] {
    var buttons = [BookButtonType]()
  
    switch self {
    case .canBorrow:
      buttons.append(.get)
      if book.hasSample && previewEnabled {
        buttons.append(book.isAudiobook ? .audiobookSample : .sample)
      }
    case .canHold:
      buttons.append(.reserve)
      if book.hasSample && previewEnabled {
        buttons.append(book.isAudiobook ? .audiobookSample : .sample)
      }
    case .holding:
      buttons.append(.manageHold)
      if book.hasSample && previewEnabled {
        buttons.append(book.isAudiobook ? .audiobookSample : .sample)
      }
    case .holdingFrontOfQueue:
      buttons.append(.get)
      if book.hasSample && previewEnabled {
        buttons.append(book.isAudiobook ? .audiobookSample : .sample)
      }
    case .managingHold:
      buttons = [.cancelHold, .close]
    case .downloadNeeded:
      if let authDef = TPPUserAccount.sharedAccount().authDefinition,
         authDef.needsAuth || book.defaultAcquisitionIfOpenAccess != nil {
        buttons = [.download, .return]
      } else {
        buttons = [.download, .remove]
      }
    case .downloadSuccessful, .used:
      switch book.defaultBookContentType {
      case .audiobook:
        buttons.append(.listen)
      case .pdf, .epub:
        buttons.append(.read)
      case .unsupported:
        break
      }

      if let authDef = TPPUserAccount.sharedAccount().authDefinition,
         authDef.needsAuth ||
          book.defaultAcquisitionIfOpenAccess != nil {
        buttons.append(.return)
      } else {
        buttons.append(.remove)
      }
    case .downloadInProgress:
      buttons = [.cancel]
    case .downloadFailed:
      buttons = [.cancel, .retry]
    case .returning:
      buttons = [.returning]
    case .unsupported:
      return []
    }

    if !book.supportsDeletion(for: self) {
      buttons = buttons.filter {
        $0 != .return || $0 != .remove
      }
    }

    return buttons
  }
}

extension TPPBook {
  func supportsDeletion(for state: BookButtonState) -> Bool {
    var fullfillmentRequired = false
    #if FEATURE_DRM_CONNECTOR
      fullfillmentRequired = state == .holding && self.revokeURL != nil
    #endif
    
    let hasFullfillmentId = TPPBookRegistry.shared.fulfillmentId(forIdentifier: self.identifier) != nil
    let isFullfiliable = !(hasFullfillmentId && fullfillmentRequired) && self.revokeURL != nil
    let needsAuthentication = self.defaultAcquisitionIfOpenAccess == nil && TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? false
    
    return isFullfiliable && !needsAuthentication
  }
}
