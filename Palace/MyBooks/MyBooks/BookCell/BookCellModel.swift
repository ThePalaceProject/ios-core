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
import PalaceAudiobookToolkit

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
      didSelectReturn()
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
    switch book.defaultBookContentType {
    case .epub:
      ReaderService.shared.openEPUB(book)
      self.isLoading = false
    case .pdf:
      guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { self.isLoading = false; return }
      let data = try? Data(contentsOf: url)
      let metadata = TPPPDFDocumentMetadata(with: book)
      let document = TPPPDFDocument(data: data ?? Data())
      if let coordinator = NavigationCoordinatorHub.shared.coordinator {
        coordinator.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
        coordinator.push(.pdf(BookRoute(id: book.identifier)))
      }
      self.isLoading = false
    case .audiobook:
      openAudiobookFromCell()
    default:
      self.isLoading = false
    }
  }

  private func openAudiobookFromCell() {
    BookOpenService.open(book)
    self.isLoading = false
  }


  private func presentAudiobookFrom(json: [String: Any], decryptor: DRMDecryptor?) {
    BookOpenService.open(book)
    self.isLoading = false
  }

  private func licenseURL(forBookIdentifier identifier: String) -> URL? {
#if LCP
    guard let contentURL = MyBooksDownloadCenter.shared.fileUrl(for: identifier) else { return nil }
    let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
    return FileManager.default.fileExists(atPath: license.path) ? license : nil
#else
    return nil
#endif
  }
  
  func didSelectReturn() {
    self.isLoading = true
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
        guard let self = self else { return }
        let identifier = self.book.identifier
        let downloaded = {
          let state = TPPBookRegistry.shared.state(for: identifier)
          return state == .downloadSuccessful || state == .used
        }()
        // Mirror BookDetailViewModel: attempt server return if revokeURL else delete local/remove registry
        if let revokeURL = self.book.revokeURL {
          TPPBookRegistry.shared.setProcessing(true, for: identifier)
          TPPOPDSFeed.withURL(revokeURL, shouldResetCache: false, useTokenIfAvailable: true) { feed, error in
            TPPBookRegistry.shared.setProcessing(false, for: identifier)
            if let feed = feed, feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry, let returnedBook = TPPBook(entry: entry) {
              if downloaded { MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier) }
              TPPBookRegistry.shared.updateAndRemoveBook(returnedBook)
            } else {
              if let errorType = (error as? [String: Any])?["type"] as? String, errorType == TPPProblemDocument.TypeNoActiveLoan {
                if downloaded { MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier) }
                TPPBookRegistry.shared.removeBook(forIdentifier: identifier)
              }
            }
            DispatchQueue.main.async { self.isLoading = false }
          }
        } else {
          if downloaded { MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier) }
          TPPBookRegistry.shared.removeBook(forIdentifier: identifier)
          DispatchQueue.main.async { self.isLoading = false }
        }
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
    MyBooksDownloadCenter.shared.startDownload(for: book)
  }
  
  func didSelectSample() {
    isLoading = true
    if book.defaultBookContentType == .audiobook {
      NotificationCenter.default.post(name: Notification.Name("ToggleSampleNotification"), object: nil)
      self.isLoading = false
      return
    }
    EpubSampleFactory.createSample(book: book) { sampleURL, error in
      DispatchQueue.main.async {
        self.isLoading = false
      }
    }
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
