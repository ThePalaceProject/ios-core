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
  
  @Published var book: TPPBook {
    didSet {
      if book.identifier != currentBookIdentifier {
        currentBookIdentifier = book.identifier
        loadBookCoverImage()
      }
    }
  }
  
  @Published var isManagingHold: Bool = false

  @Published private(set) var stableButtonState: BookButtonState = .unsupported
  @Published private var registryState: TPPBookState
  @Published private var localBookStateOverride: TPPBookState? = nil
  @Published var showHalfSheet: Bool = false

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
    // While the half sheet is shown in a transient state (e.g., .returning),
    // force the button set to match that state so we don't show read/listen.
    if localBookStateOverride == .returning { return BookButtonState.returning.buttonTypes(book: book) }
    return stableButtonState.buttonTypes(book: book)
  }
  
  
  // MARK: - Initializer
  
  init(book: TPPBook, imageCache: ImageCacheType) {
    self.book = book
    self.state = BookCellState(BookButtonState(book) ?? .unsupported)
    self.isLoading = TPPBookRegistry.shared.processing(forIdentifier: book.identifier)
    self.currentBookIdentifier = book.identifier
    self.imageCache = imageCache
    self.registryState = TPPBookRegistry.shared.state(for: book.identifier)
    self.stableButtonState = self.computeButtonState(book: book, registryState: self.registryState, isManagingHold: self.isManagingHold)
    registerForNotifications()
    loadBookCoverImage()
    bindRegistryState()
    setupStableButtonState()
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

  private func bindRegistryState() {
    TPPBookRegistry.shared.bookStatePublisher
      .filter { [weak self] in $0.0 == self?.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        self?.registryState = newState
      }
      .store(in: &cancellables)
  }

  private func computeButtonState(book: TPPBook, registryState: TPPBookState, isManagingHold: Bool) -> BookButtonState {
    let availability = book.defaultAcquisition?.availability
    let isProcessingDownload = isLoading || registryState == .downloading
    if case .holding = registryState, isManagingHold { return .managingHold }
    return BookButtonMapper.map(
      registryState: registryState,
      availability: availability,
      isProcessingDownload: isProcessingDownload
    )
  }

  private func setupStableButtonState() {
    Publishers.CombineLatest3($book, $registryState, $isManagingHold)
      .map { [weak self] book, state, isManaging in
        self?.computeButtonState(book: book, registryState: state, isManagingHold: isManaging) ?? .unsupported
      }
      .removeDuplicates()
      .debounce(for: .milliseconds(180), scheduler: DispatchQueue.main)
      .receive(on: DispatchQueue.main)
      .assign(to: &$stableButtonState)
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
    case .return:
      isManagingHold = false
      bookState = .returning
      showHalfSheet = true
    case .remove, .returning, .cancelHold, .manageHold:
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
    BookService.open(book)
    self.isLoading = false
  }


  private func presentAudiobookFrom(json: [String: Any], decryptor: DRMDecryptor?) {
    BookService.open(book)
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
    let identifier = self.book.identifier
    MyBooksDownloadCenter.shared.returnBook(withIdentifier: identifier) { [weak self] in
      DispatchQueue.main.async { self?.isLoading = false }
    }
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
      NotificationCenter.default.post(
        name: Notification.Name("ToggleSampleNotification"),
        object: nil,
        userInfo: ["bookIdentifier": book.identifier, "action": "toggle"]
      )
      self.isLoading = false
      return
    }
    EpubSampleFactory.createSample(book: book) { sampleURL, error in
      DispatchQueue.main.async {
        self.isLoading = false
        if let error = error {
          Log.debug("Sample generation error for \(self.book.title): \(error.localizedDescription)", "")
          return
        }
        if let sampleWebURL = sampleURL as? EpubSampleWebURL {
          let web = BundledHTMLViewController(fileURL: sampleWebURL.url, title: self.book.title)
          if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate, let top = appDelegate.topViewController() {
            top.present(web, animated: true)
          }
          return
        }
        if let url = sampleURL?.url {
          let web = BundledHTMLViewController(fileURL: url, title: self.book.title)
          if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate, let top = appDelegate.topViewController() {
            top.present(web, animated: true)
          }
        }
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
      // Mirror BookDetail behavior by using a local override for transient UI states
      // like .returning, while otherwise reflecting the registry state.
      localBookStateOverride ?? registryState
    }
    set {
      // Only persist a local override for the returning flow; otherwise clear it
      // to fall back to the live registry state.
      if newValue == .returning {
        localBookStateOverride = .returning
      } else {
        localBookStateOverride = nil
      }
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
