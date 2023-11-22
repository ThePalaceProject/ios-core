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

class BookCellModel: ObservableObject {
  typealias DisplayStrings = Strings.BookCell

  @Published var image = ImageProviders.MyBooksView.bookPlaceholder ?? UIImage()
  @Published var showAlert: AlertModel?
  @Published var isLoading: Bool = false {
    didSet {
      statePublisher.send(isLoading)
    }
  }

  var statePublisher = PassthroughSubject<Bool, Never>()
  var state: BookCellState
  var book: TPPBook
  var title: String { book.title }
  var authors: String { book.authors ?? "" }
  var showUnreadIndicator: Bool {
    if case .normal(let bookState) = state, bookState == .downloadSuccessful {
      return true
    } else {
      return false
    }
  }
  
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
    registerForNotifications()
    loadBookCoverImage()
  }
  
  private func registerForNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(updateButtons),
                                           name: .TPPReachabilityChanged,
                                           object: nil)
  }
  
  private func loadBookCoverImage() {
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

    var date: Date?

    book.defaultAcquisition?.availability.matchUnavailable(
        nil,
        limited: { limited in
          if let until = limited.until, until.timeIntervalSinceNow > 0 { date = until }
        },
        unlimited: nil,
        reserved: nil,
        ready: { ready in
          if let until = ready.until, until.timeIntervalSinceNow > 0 { date = until }
        }
      )

    return date
  }

  @objc private func updateButtons() {
    isLoading = false
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
    self.buttonDelegate?.didSelectRead(for: book) { [weak self] in
      self?.isLoading = false
    }
  }

  func didSelectReturn() {
    var title = ""
    var message = ""
    var confirmButtonTitle = ""
    let deleteAvailable = (book.defaultAcquisitionIfOpenAccess != nil) || !(TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? true)

    switch TPPBookRegistry.shared.state(for: book.identifier) {
    case .Used,
        .SAMLStarted,
        .Downloading,
        .Unregistered,
        .DownloadFailed,
        .DownloadNeeded,
        .DownloadSuccessful:
      title = deleteAvailable ? DisplayStrings.delete : DisplayStrings.return
      message = deleteAvailable ? String.localizedStringWithFormat(DisplayStrings.deleteMessage, book.title) :
      String.localizedStringWithFormat(DisplayStrings.returnMessage, book.title)
      confirmButtonTitle = deleteAvailable ? DisplayStrings.delete : DisplayStrings.return
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
        self?.isLoading = true
        self?.buttonDelegate?.didSelectReturn(for: self?.book) {
          self?.isLoading = false
        }
      },
      secondaryAction: { [weak self] in
        self?.showAlert = nil
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
    isLoading = true

    self.sampleDelegate?.didSelectPlaySample(book)
  }

  func didSelectCancel() {
    MyBooksDownloadCenter.shared.cancelDownload(for: book.identifier)
  }
}
