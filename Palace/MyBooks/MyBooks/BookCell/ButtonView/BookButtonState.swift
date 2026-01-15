//
//  BookButtonState.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

enum BookButtonState: Equatable {
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
    case .holding, .holdingFrontOfQueue:
      if isHoldReady(book: book) {
        buttons = [.get, .cancelHold]
      } else {
        buttons.append(.manageHold)
        
        if book.hasSample && previewEnabled {
          buttons.append(book.isAudiobook ? .audiobookSample : .sample)
        }
      }
      
    case .managingHold:
      if isHoldReady(book: book) {
        buttons = [.get, .cancelHold]
      } else {
        buttons = [.cancelHold]
      }
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
  
  private func isHoldReady(book: TPPBook) -> Bool {
    guard let availability = book.defaultAcquisition?.availability else { return false }
    
    var isReady = false
    availability.matchUnavailable { _ in
      isReady = false
    } limited: { _ in  
      isReady = false
    } unlimited: { _ in
      isReady = false  
    } reserved: { _ in
      isReady = false  // Still waiting in queue
    } ready: { _ in
      isReady = true   // Hold is ready to borrow!
    }
    
    return isReady
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
