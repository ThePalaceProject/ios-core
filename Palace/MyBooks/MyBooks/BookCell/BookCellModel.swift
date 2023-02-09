//
//  BookCellModel.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

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

struct AlertModel: Identifiable {
  let id = UUID()
  var title: String
  var message: String
  var buttonTitle: String
  var primaryAction: () -> Void
  var secondaryAction: () -> Void
}

class BookCellModel: ObservableObject {
  typealias DisplayStrings = Strings.BookCell
  var state: BookCellState
  var title: String { book.title }
  var authors: String { book.authors ?? "" }
  var book: TPPBook
  var showUnreadIndicator: Bool {
    if case .normal(let bookState) = state, bookState == .downloadSuccessful {
      return true
    } else {
      return false
    }
  }
  
  @Published var showAlert: AlertModel?
  @Published var isLoading: Bool = false
  @Published var image = ImageProviders.MyBooksView.bookPlaceholder ?? UIImage()

  var buttonTypes: [BookButtonType] {
    state.buttonState.buttonTypes(book: book)
  }

  private weak var buttonDelegate = TPPBookCellDelegate.shared()
  private weak var sampleDelegate: TPPBookButtonsSampleDelegate?
  private weak var downloadDelegate: TPPBookDownloadCancellationDelegate?

  init(book: TPPBook) {
    self.book = book

    self.state = BookCellState(BookButtonState(book) ?? .unsupported)
    self.isLoading = TPPBookRegistry.shared.processing(forIdentifier: book.identifier)
    loadImage()
  }
  
  private func loadImage() {
    guard let cachedImage = TPPBookRegistry.shared.cachedThumbnailImage(for: book) else {
      TPPBookRegistry.shared.thumbnailImage(for: book) { image in
        guard let image = image else { return }
        self.image = image
      }
      return
    }

    self.image = cachedImage
  }

  func indicatorDate(for buttonType: BookButtonType) -> Date? {
    guard buttonType.displaysIndicator else {
      return nil
    }

    var date: Date? = nil

    switch state.buttonState {
    case .downloadNeeded, .used:
      book.defaultAcquisition?.availability.matchUnavailable(
        nil,
        limited: { limited in
          if let until = limited.until,
             until.timeIntervalSinceNow > 0
          {
            date = until
          }
        },
        unlimited: nil,
        reserved: nil,
        ready: { ready in
          if let until = ready.until,
             until.timeIntervalSinceNow > 0
          {
            date = until
          }
        })
    default:
      return date
    }
    return date
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
    isLoading = true
    self.buttonDelegate?.didSelectRead(for: book)
    TPPRootTabBarController.shared().dismiss(animated: true)
  }

  func didSelectReturn() {
    var title = ""
    var message = ""
    var confirmButtonTitle = ""
    let shouldDelete = (book.defaultAcquisitionIfOpenAccess != nil) || !(TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? true)

    switch TPPBookRegistry.shared.state(for: book.identifier) {
    case .Used,
        .SAMLStarted,
        .Downloading,
        .Unregistered,
        .DownloadFailed,
        .DownloadNeeded,
        .DownloadSuccessful:
      title = shouldDelete ? DisplayStrings.delete : DisplayStrings.return
      message = shouldDelete ? String.localizedStringWithFormat(DisplayStrings.deleteMessage, book.title) :
      String.localizedStringWithFormat(DisplayStrings.returnMessage, book.title)
      confirmButtonTitle = shouldDelete ? DisplayStrings.delete : DisplayStrings.return
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
      primaryAction: { [weak self] in
        self?.buttonDelegate?.didSelectReturn(for: self?.book)
        self?.isLoading = true
      },
      secondaryAction: { [weak self] in
        self?.showAlert = nil
      }
    )
  }

  func didSelectDownload() {
    isLoading = true

    if case .canHold = state.buttonState {
      TPPUserNotifications.requestAuthorization()
    }
    
    buttonDelegate?.didSelectDownload(for: book)
  }
  
  func didSelectSample() {
    isLoading = true

    self.sampleDelegate?.didSelectPlaySample(book)
  }

  func didSelectCancel() {
    TPPMyBooksDownloadCenter.shared().cancelDownload(forBookIdentifier: book.identifier)
  }
}
