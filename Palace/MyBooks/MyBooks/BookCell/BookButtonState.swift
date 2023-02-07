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
  case downloadFailed
  case unsupported
}

extension BookButtonState {
  func buttonTypes(book: TPPBook) -> [BookButtonType] {
    switch self {
    case .canBorrow:
      return [.get, book.defaultBookContentType == .audiobook ? .audiobookSample : .sample]
    case .canHold:
      return [.reserve,book.defaultBookContentType == .audiobook ? .audiobookSample : .sample]
    case .holding:
      return [.remove,book.defaultBookContentType == .audiobook ? .audiobookSample : .sample]
    case .holdingFrontOfQueue:
      return [.get, .remove]
    case .downloadNeeded:
      guard let authDef = TPPUserAccount.sharedAccount().authDefinition,
            authDef.needsAuth ||
              book.defaultAcquisitionIfOpenAccess != nil
      else {
        return [.download, .remove]
      }
    
      return [.download, .return]
    case .downloadSuccessful, .used:
      var buttonArray = [BookButtonType]()

      switch book.defaultBookContentType {
      case .audiobook:
        buttonArray.append(.listen)
      case .pdf, .epub:
        buttonArray.append(.read)
      case .unsupported:
        break
      }

      guard let authDef = TPPUserAccount.sharedAccount().authDefinition,
            authDef.needsAuth ||
              book.defaultAcquisitionIfOpenAccess != nil
      else {
        buttonArray.append(.remove)
        return buttonArray
      }
      
      buttonArray.append(.return)
      return buttonArray
    case .downloadInProgress:
      return [.cancel]
    case .downloadFailed:
      return [.retry, .cancel]
    case .unsupported:
      return []
    }
  }
}

enum BookButtonType: String {
  case get
  case reserve
  case download
  case read
  case listen
  case retry
  case cancel
  case sample
  case audiobookSample
  case remove
  case `return`

  var localizedTitle: String {
    NSLocalizedString(self.rawValue, comment: "Book Action Button title")
  }
}

extension BookButtonState {
  
  init?(_ book: TPPBook) {
    let bookState = TPPBookRegistry.shared.state(for: book.identifier)
    switch bookState {
    case .Unregistered, .Holding:
      guard let buttonState = Self.init(book.defaultAcquisition?.availability) else {
        TPPErrorLogger.logError(withCode: .noURL, summary: "Unable to determine BookButtonsViewState because no Availability was provided")
        return nil
      }

      self = buttonState
    case .DownloadNeeded:
      self = .downloadNeeded
    case .DownloadSuccessful:
      self = .downloadSuccessful
    case .SAMLStarted, .Downloading:
      // SAML started is part of download process, in this step app does authenticate user but didn't begin file downloading yet
      // The cell should present progress bar and "Requesting" description on its side
      self = .downloadInProgress
    case .DownloadFailed:
      self = .downloadFailed
    case .Used:
      self = .used
    case .Unsupported:
      self = .unsupported
    }
  }

  init?(_ availability: TPPOPDSAcquisitionAvailability?) {
    guard let availability = availability else {
      return nil
    }
    
    var state: BookButtonState = .unsupported
    availability.matchUnavailable { _ in
      state = .canHold
    } limited: { _ in
      state = .canBorrow
    } unlimited: { _ in
      state = .canBorrow
    } reserved: { _ in
      state = .holdingFrontOfQueue
    }

    self = state
  }
}
