import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit

enum BookService {
  static func open(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
    let resolvedBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) ?? book

    switch resolvedBook.defaultBookContentType {
    case .epub:
      Task { @MainActor in
        ReaderService.shared.openEPUB(resolvedBook)
        onFinish?()
      }
    case .pdf:
      Task { @MainActor in
        presentPDF(resolvedBook) { onFinish?() }
      }
    case .audiobook:
      presentAudiobook(resolvedBook, onFinish: onFinish)
    default:
      onFinish?()
    }
  }
  
  @MainActor private static func presentPDF(_ book: TPPBook, completion: (() -> Void)? = nil) {
    guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { completion?(); return }
    let data = try? Data(contentsOf: url)
    let metadata = TPPPDFDocumentMetadata(with: book)
    let document = TPPPDFDocument(data: data ?? Data())
    if let coordinator = NavigationCoordinatorHub.shared.coordinator {
      coordinator.storePDF(document: document, metadata: metadata, forBookId: book.identifier)
      coordinator.push(.pdf(BookRoute(id: book.identifier)))
    }
    completion?()
  }

  private static func presentAudiobook(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
#if LCP
    if LCPAudiobooks.canOpenBook(book) {
      if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier), FileManager.default.fileExists(atPath: localURL.path) {
        buildAndPresentAudiobook(book: book, lcpSourceURL: localURL, onFinish: onFinish)
        return
      }
      if let license = licenseURL(forBookIdentifier: book.identifier) {
        buildAndPresentAudiobook(book: book, lcpSourceURL: license, onFinish: onFinish)
        return
      }
    }
#endif
    if let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier),
       FileManager.default.fileExists(atPath: url.path),
       let data = try? Data(contentsOf: url),
       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
      presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
      return
    }

    fetchOpenAccessManifest(for: book) { json in
      guard let json else {
        showAudiobookTryAgainError()
        onFinish?()
        return
      }
      presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
    }
  }

#if LCP
  private static func buildAndPresentAudiobook(book: TPPBook, lcpSourceURL: URL) {
    guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else {
      showAudiobookTryAgainError()
      return
    }
    if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
      presentAudiobookFrom(book: book, json: cached, decryptor: lcpAudiobooks)
      return
    }
    lcpAudiobooks.contentDictionary { dict, error in
      DispatchQueue.main.async {
        guard error == nil, let json = dict as? [String: Any] else {
          showAudiobookTryAgainError()
          return
        }
        presentAudiobookFrom(book: book, json: json, decryptor: lcpAudiobooks)
      }
    }
  }
#endif

#if LCP
  private static func buildAndPresentAudiobook(book: TPPBook, lcpSourceURL: URL, onFinish: (() -> Void)?) {
    guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else {
      showAudiobookTryAgainError()
      onFinish?()
      return
    }
    if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
      presentAudiobookFrom(book: book, json: cached, decryptor: lcpAudiobooks, onFinish: onFinish)
      return
    }
    lcpAudiobooks.contentDictionary { dict, error in
      DispatchQueue.main.async {
        guard error == nil, let json = dict as? [String: Any] else {
          showAudiobookTryAgainError()
          onFinish?()
          return
        }
        presentAudiobookFrom(book: book, json: json, decryptor: lcpAudiobooks, onFinish: onFinish)
      }
    }
  }
#endif

  private static func presentAudiobookFrom(
    book: TPPBook,
    json: [String: Any],
    decryptor: DRMDecryptor?,
    onFinish: (() -> Void)? = nil
  ) {
    var jsonDict = json
    jsonDict["id"] = book.identifier

    let vendorCompletion: (Foundation.NSError?) -> Void = { (error: Foundation.NSError?) in
      Task { @MainActor in
        guard error == nil else {
          showAudiobookTryAgainError()
          onFinish?()
          return
        }

        guard
          let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: []),
          let manifest = try? Manifest.customDecoder().decode(Manifest.self, from: jsonData),
          let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: book.identifier,
            decryptor: decryptor,
            token: book.bearerToken
          )
        else {
          showAudiobookTryAgainError()
          onFinish?()
          return
        }

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""]) 
        var timeTracker: AudiobookTimeTracker?
        if
          let libraryId = AccountsManager.shared.currentAccount?.uuid,
          let url = book.timeTrackingURL
        {
          timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: url)
        }

        let networkService: AudiobookNetworkService = DefaultAudiobookNetworkService(
          tracks: audiobook.tableOfContents.allTracks,
          decryptor: decryptor
        )

        let manager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: networkService,
          playbackTrackerDelegate: timeTracker
        )

        let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book)
        manager.bookmarkDelegate = bookmarkLogic

        let playbackModel = AudiobookPlaybackModel(audiobookManager: manager)
        if let cover = book.coverImage {
          playbackModel.updateCoverImage(cover)
        } else {
          Task {
            if let img = await TPPBookCoverRegistry.shared.coverImage(for: book) {
              await MainActor.run { playbackModel.updateCoverImage(img) }
            }
          }
        }

        // Determine initial playback position with validation for newly downloaded books
        let shouldRestorePosition = shouldRestoreBookmarkPosition(for: book)
        
        if shouldRestorePosition,
          let dict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.locationStringDictionary(),
          let localBookmark = AudioBookmark.create(locatorData: dict),
          let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
          ),
          isValidPosition(localPosition, in: audiobook.tableOfContents)
        {
          ATLog(.info, "Restoring bookmark position for \(book.title)")
          manager.audiobook.player.play(at: localPosition, completion: nil)
          playbackModel.jumpToInitialLocation(localPosition)
          playbackModel.beginSaveSuppression(for: 3.0)
        } else {
          // Start from beginning for newly downloaded books or invalid bookmarks
          if let firstTrack = audiobook.tableOfContents.allTracks.first {
            let startPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobook.tableOfContents.tracks)
            ATLog(.info, "Starting \(book.title) from beginning")
            manager.audiobook.player.play(at: startPosition, completion: nil)
            playbackModel.jumpToInitialLocation(startPosition)
            playbackModel.beginSaveSuppression(for: 2.0)
          } else {
            manager.audiobook.player.play()
          }
        }

        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          let route = BookRoute(id: book.identifier)
          coordinator.storeAudioModel(playbackModel, forBookId: route.id)
          coordinator.push(.audio(route))

          TPPBookRegistry.shared.syncLocation(for: book) { (remoteBookmark: AudioBookmark?) in
            guard
              let remoteBookmark,
              let remotePosition = TrackPosition(
                audioBookmark: remoteBookmark,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              )
            else { return }

            let localDict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.locationStringDictionary()

            var shouldMove = true
            if
              let localDict,
              let local = AudioBookmark.create(locatorData: localDict),
              let localPos = TrackPosition(
                audioBookmark: local,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              )
            {
              shouldMove = remotePosition.timestamp > localPos.timestamp
                && remotePosition.description != localPos.description
            }

            if shouldMove {
              manager.audiobook.player.play(at: remotePosition, completion: nil)
              playbackModel.beginSaveSuppression(for: 2.0)
            }
          }

          onFinish?()
        } else {
          showAudiobookTryAgainError()
          onFinish?()
        }
      }
    }

    AudioBookVendorsHelper.updateVendorKey(book: jsonDict, completion: vendorCompletion)
  }

  private static func fetchOpenAccessManifest(for book: TPPBook, completion: @escaping ([String: Any]?) -> Void) {
    guard let url = book.defaultAcquisition?.hrefURL else { completion(nil); return }
    let task = TPPNetworkExecutor.shared.download(url) { data, response, error in
      guard error == nil,
            let data = data,
            let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        completion(nil)
        return
      }
      completion(json)
    }
    task.resume()
  }

  private static func licenseURL(forBookIdentifier identifier: String) -> URL? {
#if LCP
    guard let contentURL = MyBooksDownloadCenter.shared.fileUrl(for: identifier) else { return nil }
    let license = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
    return FileManager.default.fileExists(atPath: license.path) ? license : nil
#else
    return nil
#endif
  }

  private static func showAudiobookTryAgainError() {
    let alert = TPPAlertUtils.alert(title: Strings.Error.openFailedError, message: Strings.Error.tryAgain)
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  /// Determines if bookmark position should be restored for this book
  private static func shouldRestoreBookmarkPosition(for book: TPPBook) -> Bool {
    // Check if book was recently downloaded (within last 24 hours)
    let bookState = TPPBookRegistry.shared.state(for: book.identifier)
    
    // For newly downloaded books, always start from beginning
    if bookState == .downloadSuccessful {
      // Check if download was recent
      if let downloadDate = getDownloadDate(for: book.identifier) {
        let hoursSinceDownload = Date().timeIntervalSince(downloadDate) / 3600
        if hoursSinceDownload < 1.0 { // Less than 1 hour ago
          return false // Start from beginning
        }
      }
    }
    
    // For books with existing progress, restore position
    return true
  }
  
  /// Validates that a position is reasonable and not corrupted
  private static func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
    // Check if position is within reasonable bounds
    guard position.timestamp >= 0 && position.timestamp.isFinite else {
      ATLog(.warn, "Invalid position timestamp: \(position.timestamp)")
      return false
    }
    
    // Check if track exists in table of contents
    guard tableOfContents.tracks.track(forKey: position.track.key) != nil else {
      ATLog(.warn, "Position references non-existent track: \(position.track.key)")
      return false
    }
    
    // Check if position is within reasonable bounds (basic validation)
    let totalDuration = tableOfContents.tracks.totalDuration
    let positionDuration = position.durationToSelf()
    
    if positionDuration > totalDuration * 0.95 {
      ATLog(.warn, "Position is too close to end of book, starting from beginning")
      return false
    }
    
    return true
  }
  
  /// Gets download date for a book (placeholder - would integrate with download tracking)
  private static func getDownloadDate(for bookId: String) -> Date? {
    // This would integrate with MyBooksDownloadCenter to get actual download date
    // For now, return nil to be conservative
    return nil
  }
}


