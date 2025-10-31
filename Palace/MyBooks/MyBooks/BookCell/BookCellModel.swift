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
  
  @Published var image = UIImage()
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
  #if LCP
  private var didPrefetchLCPStreaming = false
  #endif
  
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
  @Published private(set) var registryState: TPPBookState
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
    self.image = generatePlaceholder(for: book)
    registerForNotifications()
    loadBookCoverImage()
    bindRegistryState()
    setupStableButtonState()
    #if LCP
    prefetchLCPStreamingIfPossible()
    #endif
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  // MARK: - Image Loading
  
  private func generatePlaceholder(for book: TPPBook) -> UIImage {
    let size = CGSize(width: 80, height: 120)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    return UIGraphicsImageRenderer(size: size, format: format)
      .image { ctx in
        if let view = NYPLTenPrintCoverView(
          frame: CGRect(origin: .zero, size: size),
          withTitle: book.title,
          withAuthor: book.authors ?? "Unknown Author",
          withScale: 0.4
        ) {
          view.layer.render(in: ctx.cgContext)
        }
      }
  }
  
  func loadBookCoverImage() {
    let simpleKey = book.identifier
    let thumbnailKey = "\(book.identifier)_thumbnail"
    
    if let cachedImage = imageCache.get(for: simpleKey) ?? imageCache.get(for: thumbnailKey) {
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
    
    TPPBookRegistry.shared.thumbnailImage(for: self.book) { [weak self] fetchedImage in
      guard let self = self, let fetchedImage else { return }
      self.setImageAndCache(fetchedImage)
      self.isLoading = false
      self.isFetchingImage = false
    }
  }
  
  private func setImageAndCache(_ image: UIImage) {
    let simpleKey = book.identifier
    let thumbnailKey = "\(book.identifier)_thumbnail"
    imageCache.set(image, for: simpleKey)
    imageCache.set(image, for: thumbnailKey)
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
      .sink { [weak self] newState in
        self?.registryState = newState
      }
      .store(in: &cancellables)
  }

  private func computeButtonState(book: TPPBook, registryState: TPPBookState, isManagingHold: Bool) -> BookButtonState {
    let availability = book.defaultAcquisition?.availability
    // Only reflect actual download state from registry; do not treat UI image loading as download-in-progress
    let isProcessingDownload = registryState == .downloading
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
    case .download, .retry, .get:
      didSelectDownload()
    case .reserve:
      didSelectReserve()
    case .return:
      isManagingHold = false
      bookState = .returning
      showHalfSheet = true
    case .manageHold:
      isManagingHold = true
      bookState = .holding
      showHalfSheet = true
    case .remove, .returning, .cancelHold:
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
    BookService.open(book) { [weak self] in
      self?.isLoading = false
    }
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

  #if LCP
  private func prefetchLCPStreamingIfPossible() {
    guard !didPrefetchLCPStreaming, LCPAudiobooks.canOpenBook(book) else { return }
    if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier), FileManager.default.fileExists(atPath: localURL.path) {
      return
    }
    guard let license = licenseURL(forBookIdentifier: book.identifier), let lcpAudiobooks = LCPAudiobooks(for: license) else { return }
    didPrefetchLCPStreaming = true
    lcpAudiobooks.startPrefetch()
  }
  #endif
  
  func didSelectReturn() {
    self.isLoading = true
    let identifier = self.book.identifier
    MyBooksDownloadCenter.shared.returnBook(withIdentifier: identifier) { [weak self] in
      self?.isLoading = false
      self?.isManagingHold = false
      self?.showHalfSheet = false
    }
  }
  
  func didSelectDownload() {
    let account = TPPUserAccount.sharedAccount()
    if account.needsAuth && !account.hasCredentials() {
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        guard let self else { return }
        self.startDownloadNow()
      }
      return
    }
    startDownloadNow()
  }

  private func startDownloadNow() {
    if case .canHold = state.buttonState {
      TPPUserNotifications.requestAuthorization()
    }
    MyBooksDownloadCenter.shared.startDownload(for: book)
  }

  func didSelectReserve() {
    isLoading = true
    let account = TPPUserAccount.sharedAccount()
    if account.needsAuth && !account.hasCredentials() {
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        guard let self else { return }
        TPPUserNotifications.requestAuthorization()
        Task {
          do {
            _ = try await MyBooksDownloadCenter.shared.borrowAsync(self.book, attemptDownload: false)
          } catch {
            Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
          }
          self.isLoading = false
        }
      }
      return
    }
    TPPUserNotifications.requestAuthorization()
    Task {
      do {
        _ = try await MyBooksDownloadCenter.shared.borrowAsync(book, attemptDownload: false)
      } catch {
        Log.error(#file, "Failed to borrow book: \(error.localizedDescription)")
      }
      self.isLoading = false
    }
  }
  
  func didSelectSample() {
    isLoading = true
    if book.defaultBookContentType == .audiobook {
      SamplePreviewManager.shared.toggle(for: book)
      self.isLoading = false
      return
    }
    EpubSampleFactory.createSample(book: book) { sampleURL, error in
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
  var bookState: TPPBookState {
    get {
      localBookStateOverride ?? registryState
    }
    set {
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
