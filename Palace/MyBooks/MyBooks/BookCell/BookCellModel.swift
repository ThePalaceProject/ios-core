//
//  BookCellModel.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine

enum BookCellState {
  case normal(BookButtonState)
  case downloading(BookButtonState)
  case downloadFailed(BookButtonState)
  
  var buttonState: BookButtonState {
    switch self {
    case .normal(let state),
        .downloading(let state),
        .downloadFailed(let state):
      return state
    }
  }
}

extension BookCellState {
  init(_ bookButtonState: BookButtonState) {
    switch bookButtonState {
    case .downloadInProgress:
      self = .downloading(bookButtonState)
    case .downloadFailed:
      self = .downloadFailed(bookButtonState)
    default:
      self = .normal(bookButtonState)
    }
  }
}

struct AlertModel {
  var title: String
  var message: String
  var buttonTitle: String
  var action: () -> Void
}

class BookCellModel: ObservableObject {
  typealias DisplayStrings = Strings.BookCell
  var title: String
  var authors: String
  var imageURL: URL?
  var book: TPPBook
  
  @Published var showAlert: AlertModel?

  var buttonTypes: [BookButtonType] {
    state.buttonState.buttonTypes(book: book)
  }

  private weak var buttonDelegate = TPPBookCellDelegate.shared()
  private weak var sampleDelegate: TPPBookButtonsSampleDelegate?
  private weak var downloadDelegate: TPPBookDownloadCancellationDelegate?
  private var state: BookCellState

  init(book: TPPBook) {
    self.book = book
    self.title = book.title
    self.authors = book.authors ?? ""

    self.state = BookCellState(BookButtonState(book) ?? .unsupported)
    self.imageURL = book.imageThumbnailURL ?? book.imageURL
  }
}

extension BookCellModel {
  
  func callDelegate(for action: BookButtonType) {
    switch action {
    case .download, .retry, .get, .reserve:
      didSelectDownload()
    case .return, .remove:
      didSelectReturn()
    case .cancel:
      didSelectCancel()
    case .sample, .audiobookSample:
      didSelectSample()
    case .read, .listen:
      didSelectRead()
    }
  }
  
  func didSelectRead() {
    self.buttonDelegate?.didSelectRead(for: book)
    TPPRootTabBarController.shared().dismiss(animated: true)
  }
  
  func didSelectReturn() {
    var title = ""
    var message = ""
    var confirmButtonTitle = ""
    var deleteTitle = (book.defaultAcquisitionIfOpenAccess != nil) || !(TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? true)


    switch TPPBookRegistry.shared.state(for: book.identifier) {
    case .Used,
        .SAMLStarted,
        .Downloading,
        .Unregistered,
        .DownloadFailed,
        .DownloadNeeded,
        .DownloadSuccessful:
      title = deleteTitle ? DisplayStrings.delete : DisplayStrings.return
      message = deleteTitle ? DisplayStrings.deleteMessage : DisplayStrings.returnMessage
      confirmButtonTitle = deleteTitle ? DisplayStrings.delete : DisplayStrings.return
    case .Holding:
      title = DisplayStrings.removeReservation
      message = DisplayStrings.returnMessage
      confirmButtonTitle = DisplayStrings.remove
    case .Unsupported:
      return
    }
    
    showAlert = AlertModel(
      title: title,
      message: message,
      buttonTitle: confirmButtonTitle,
      action: { [weak self] in
        self?.buttonDelegate?.didSelectReturn(for: self?.book)
      }
    )
  }

  func didSelectDownload() {
    if case .canHold = state.buttonState {
      TPPUserNotifications.requestAuthorization()
    }
    
    buttonDelegate?.didSelectDownload(for: book)
  }
  
  func didSelectSample() {
    self.sampleDelegate?.didSelectPlaySample(book)
  }

  //TODO: Unused in current implementation, to be completed when updating BookDetailView
  func didSelectCancel() {}
}
