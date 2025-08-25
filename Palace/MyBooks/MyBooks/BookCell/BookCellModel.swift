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

@MainActor
class BookCellModel: ObservableObject {
  typealias DisplayStrings = Strings.BookCell
  
  @Published var image = ImageProviders.MyBooksView.bookPlaceholder ?? UIImage()
  @Published var showAlert: AlertModel?
  @Published var isLoading: Bool = false {
    didSet {
      statePublisher.send(isLoading)
    }
  }
  
  @Published private var currentBookIdentifier: String?
  
  private var cancellables = Set<AnyCancellable>()
  let imageCache: ImageCacheType
  private var isFetchingImage = false
  
  var statePublisher = PassthroughSubject<Bool, Never>()
  var state: BookCellState
  
  var book: TPPBook {
    didSet {
      if book.identifier != currentBookIdentifier {
        currentBookIdentifier = book.identifier
        loadBookCoverImage()
      }
    }
  }
  
  var isManagingHold: Bool {
    switch buttonState {
    case .managingHold, .holding, .holdingFrontOfQueue:
      true
    default:
      false
    }
  }
  
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
  
  // MARK: - Initializer
  
  init(book: TPPBook, imageCache: ImageCacheType) {
    self.book = book
    self.state = BookCellState(BookButtonState(book) ?? .unsupported)
    self.isLoading = TPPBookRegistry.shared.processing(forIdentifier: book.identifier)
    self.currentBookIdentifier = book.identifier
    self.imageCache = imageCache
    registerForNotifications()
    loadBookCoverImage()
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  // MARK: - Image Loading
  
  func loadBookCoverImage() {
    if let cachedImage = imageCache.get(for: book.identifier) {
      image = cachedImage
    } else if let registryImage = TPPBookRegistry.shared.cachedThumbnailImage(for: book) {
      setImageAndCache(registryImage)
    } else {
      fetchAndCacheImage()
    }
  }
  
  private func fetchAndCacheImage() {
    guard !isFetchingImage else { return }
    isFetchingImage = true
    isLoading = true
    
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      TPPBookRegistry.shared.thumbnailImage(for: self.book) { [weak self] fetchedImage in
        guard let self = self, let fetchedImage else { return }
        self.setImageAndCache(fetchedImage)
        self.isLoading = false
        self.isFetchingImage = false
      }
    }
  }
  
  private func setImageAndCache(_ image: UIImage) {
    imageCache.set(image, for: book.identifier)
    self.image = image
  }
  
  // MARK: - Notification Handling
  
  private func registerForNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(updateButtons),
                                           name: .TPPReachabilityChanged, object: nil)
  }
  
  @objc private func updateButtons() {
    Task { @MainActor [weak self] in
      self?.isLoading = false
    }
  }
}

extension BookCellModel {
  func callDelegate(for action: BookButtonType) {
    switch action {
    case .download, .retry, .get, .reserve:
      didSelectDownload()
    case .return, .remove, .returning, .cancelHold, .manageHold:
      self.isLoading = true
      self.buttonDelegate?.didSelectReturn(for: self.book) {}
    case .cancel:
      didSelectCancel()
    case .sample, .audiobookSample:
      didSelectSample()
    case .read, .listen:
      didSelectRead()
    case .close:
      return
    }
  }
  
  func didSelectRead() {
    isLoading = true
    self.buttonDelegate?.didSelectRead(for: book) { [weak self] in
      DispatchQueue.main.async {
        self?.isLoading = false
      }
    }
  }
  
  func didSelectReturn() {
    var title = ""
    var message = ""
    var confirmButtonTitle = ""
    let deleteAvailable = (book.defaultAcquisitionIfOpenAccess != nil) || !(TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? true)
    
    switch TPPBookRegistry.shared.state(for: book.identifier) {
    case .used,
        .SAMLStarted,
        .downloading,
        .unregistered,
        .downloadFailed,
        .downloadNeeded,
        .downloadSuccessful,
        .returning:
      title = deleteAvailable ? DisplayStrings.delete : DisplayStrings.return
      message = deleteAvailable ? String.localizedStringWithFormat(DisplayStrings.deleteMessage, book.title) :
      String.localizedStringWithFormat(DisplayStrings.returnMessage, book.title)
      confirmButtonTitle = deleteAvailable ? DisplayStrings.delete : DisplayStrings.return
    case .holding:
      title = DisplayStrings.removeReservation
      message = DisplayStrings.returnMessage
      confirmButtonTitle = DisplayStrings.remove
    case .unsupported:
      return
    }
    
    showAlert = AlertModel(
      title: title,
      message: message,
      buttonTitle: confirmButtonTitle,
      primaryAction: { [weak self] in
        self?.isLoading = true
        self?.buttonDelegate?.didSelectReturn(for: self?.book) { }
      },
      secondaryAction: { [weak self] in
        self?.showAlert = nil
        self?.isLoading = false
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

extension BookCellModel: BookButtonProvider {
  func handleAction(for type: BookButtonType) {
    callDelegate(for: type)
  }
  
  func isProcessing(for type: BookButtonType) -> Bool {
    isLoading
  }
}

extension BookCellModel: HalfSheetProvider {
  /// Always read the "live" state from the registry.
  var bookState: TPPBookState {
    get {
      TPPBookRegistry.shared.state(for: book.identifier)
    }
    set {
      TPPBookRegistry.shared.setState(newValue, for: book.identifier)
    }
  }
  
  var buttonState: BookButtonState {
    let registryState = TPPBookRegistry.shared.state(for: book.identifier)
    let availability = book.defaultAcquisition?.availability
    let isDownloading = isLoading || registryState == .downloading
    return BookButtonMapper.map(
      registryState: registryState,
      availability: availability,
      isProcessingDownload: isDownloading
    )
  }
  
  var isFullSize: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
  }
  
  var downloadProgress: Double {
    MyBooksDownloadCenter.shared.downloadProgress(for: book.identifier)
  }
}
