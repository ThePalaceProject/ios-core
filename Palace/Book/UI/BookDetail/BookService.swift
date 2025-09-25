import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit

enum BookService {
  private static var openingBooks = Set<String>()
  
  static func open(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
    // Prevent multiple simultaneous opens of the same book
    guard !openingBooks.contains(book.identifier) else {
      ATLog(.warn, "Book \(book.title) is already being opened, ignoring duplicate request")
      onFinish?()
      return
    }
    
    openingBooks.insert(book.identifier)
    let resolvedBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) ?? book

    openAfterTokenRefresh(resolvedBook, onFinish: onFinish)
  }
  
  private static func openAfterTokenRefresh(_ book: TPPBook, onFinish: (() -> Void)?) {
    switch book.defaultBookContentType {
    case .epub:
      Task { @MainActor in
        ReaderService.shared.openEPUB(book)
        openingBooks.remove(book.identifier)
        onFinish?()
      }
    case .pdf:
      Task { @MainActor in
        presentPDF(book) { 
          openingBooks.remove(book.identifier)
          onFinish?() 
        }
      }
    case .audiobook:
      presentAudiobook(book) {
        openingBooks.remove(book.identifier)
        onFinish?()
      }
    default:
      openingBooks.remove(book.identifier)
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
        openingBooks.remove(book.identifier)
        onFinish?()
        return
      }
      presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
    }
  }

#if LCP
  private static func buildAndPresentAudiobook(book: TPPBook, lcpSourceURL: URL, onFinish: (() -> Void)?) {
    guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else {
      showAudiobookTryAgainError()
      openingBooks.remove(book.identifier)
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
          openingBooks.remove(book.identifier)
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
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }

        ATLog(.info, "Creating audiobook with bearerToken: '\(book.bearerToken ?? "nil")' for \(book.title)")
        
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
          openingBooks.remove(book.identifier)
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

        // Present the AudiobookPlayerView first, then start playback
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          let route = BookRoute(id: book.identifier)
          coordinator.storeAudioModel(playbackModel, forBookId: route.id)
          coordinator.push(.audio(route))
          
          // Now determine and start playback after a brief delay for UI to settle
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            startPlaybackAfterPresentation(book: book, audiobook: audiobook, manager: manager, playbackModel: playbackModel)
          }

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
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                manager.audiobook.player.play(at: remotePosition, completion: nil)
              }
              playbackModel.beginSaveSuppression(for: 2.0)
            }
          }

          openingBooks.remove(book.identifier)
          onFinish?()
        } else {
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
        }
      }
    }

    AudioBookVendorsHelper.updateVendorKey(book: jsonDict) { error in
      DispatchQueue.main.async {
        vendorCompletion(error)
      }
    }
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

  /// Determines if bookmark position should be restored for this book
  private static func shouldRestoreBookmarkPosition(for book: TPPBook) -> Bool {
    let bookState = TPPBookRegistry.shared.state(for: book.identifier)
    let hasLocation = TPPBookRegistry.shared.location(forIdentifier: book.identifier) != nil
    
    ATLog(.info, "Position check for \(book.title): state=\(bookState), hasLocation=\(hasLocation)")
    
    // If there's no saved location, always start from beginning
    guard hasLocation else {
      ATLog(.info, "No saved location found - starting from beginning")
      return false
    }
    
    // Always restore saved positions unless explicitly a new download
    if bookState == .downloadSuccessful {
      // Even for newly downloaded books, restore position if one exists
      // This handles cases where user previously started reading
      ATLog(.info, "Book is downloadSuccessful but has saved location - restoring position")
      return true
    }
    
    ATLog(.info, "Restoring saved position for book")
    return true
  }
  
  /// Validates that a position is reasonable and not corrupted
  private static func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
    ATLog(.info, "Validating position: track=\(position.track.index), timestamp=\(position.timestamp)")
    
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
    let percentageThrough = totalDuration > 0 ? positionDuration / totalDuration : 0
    
    ATLog(.info, "Position validation: \(Int(percentageThrough * 100))% through book")
    
    if positionDuration > totalDuration * 0.95 {
      ATLog(.warn, "Position is too close to end of book (\(Int(percentageThrough * 100))%), starting from beginning")
      return false
    }
    
    ATLog(.info, "Position validation passed")
    return true
  }
  
  /// Gets download date for a book (placeholder - would integrate with download tracking)
  private static func getDownloadDate(for bookId: String) -> Date? {
    // This would integrate with MyBooksDownloadCenter to get actual download date
    // For now, return nil to be conservative
    return nil
  }

  private static func startPlaybackAfterPresentation(
    book: TPPBook,
    audiobook: Audiobook,
    manager: DefaultAudiobookManager,
    playbackModel: AudiobookPlaybackModel
  ) {
    // Determine initial playback position with validation for newly downloaded books
    let shouldRestorePosition = shouldRestoreBookmarkPosition(for: book)
    
    ATLog(.info, "shouldRestorePosition = \(shouldRestorePosition) for \(book.title)")
    
    if shouldRestorePosition {
      if let dict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.locationStringDictionary() {
        ATLog(.info, "Found location dictionary: \(dict)")
        
        if let localBookmark = AudioBookmark.create(locatorData: dict) {
          ATLog(.info, "Created local bookmark successfully")
          
          if let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
          ) {
            ATLog(.info, "Created TrackPosition: track=\(localPosition.track.index), timestamp=\(localPosition.timestamp)")
            
            if isValidPosition(localPosition, in: audiobook.tableOfContents) {
              ATLog(.info, "Position is valid - restoring bookmark position for \(book.title)")
              playbackModel.jumpToInitialLocation(localPosition)
              playbackModel.beginSaveSuppression(for: 3.0)
              manager.audiobook.player.play(at: localPosition, completion: nil)
              return
            } else {
              ATLog(.warn, "Position validation failed")
            }
          } else {
            ATLog(.warn, "Failed to create TrackPosition from bookmark")
          }
        } else {
          ATLog(.warn, "Failed to create AudioBookmark from location data")
        }
      } else {
        ATLog(.warn, "No location dictionary found despite shouldRestorePosition = true")
      }
    }
    
    // Start from beginning for newly downloaded books or invalid bookmarks
    if let firstTrack = audiobook.tableOfContents.allTracks.first {
      let startPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobook.tableOfContents.tracks)
      ATLog(.info, "Starting \(book.title) from beginning")
      playbackModel.jumpToInitialLocation(startPosition)
      playbackModel.beginSaveSuppression(for: 2.0)
      manager.audiobook.player.play(at: startPosition, completion: nil)
    } else {
      // Ensure we set a position even when falling back to basic play()
      if let firstTrack = audiobook.tableOfContents.allTracks.first {
        let fallbackPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobook.tableOfContents.tracks)
        playbackModel.jumpToInitialLocation(fallbackPosition)
      }
      manager.audiobook.player.play()
    }
  }


  private static func showAudiobookTryAgainError() {
    let alert = TPPAlertUtils.alert(title: Strings.Error.openFailedError, message: Strings.Error.tryAgain)
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}


