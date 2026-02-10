import Foundation
import SwiftUI
import Combine
import PalaceAudiobookToolkit

enum BookService {
  private static var openingBooks = Set<String>()
  
  static func open(_ book: TPPBook, onFinish: (() -> Void)? = nil) {
    
    // Prevent multiple simultaneous opens of the same book
    guard !openingBooks.contains(book.identifier) else {
      Log.warn(#file, "Book \(book.title) is already being opened, ignoring duplicate request")
      onFinish?()
      return
    }
    
    openingBooks.insert(book.identifier)
    let resolvedBook = TPPBookRegistry.shared.book(forIdentifier: book.identifier) ?? book

    openAfterTokenRefresh(resolvedBook, onFinish: onFinish)
  }
  
  private static func openAfterTokenRefresh(_ book: TPPBook, onFinish: (() -> Void)?) {
    let userAccount = TPPUserAccount.sharedAccount()
    
    if book.defaultBookContentType == .audiobook && userAccount.authTokenHasExpired {
      Log.info(#file, "🔄 Auth token expired for audiobook - refreshing before opening")
      
      guard let username = userAccount.username,
            let password = userAccount.PIN,
            let tokenURL = userAccount.authDefinition?.tokenURL else {
        Log.error(#file, "Cannot refresh token: missing credentials or tokenURL")
        openingBooks.remove(book.identifier)
        showAudiobookTryAgainError()
        onFinish?()
        return
      }
      
      TPPNetworkExecutor.shared.executeTokenRefresh(username: username, password: password, tokenURL: tokenURL) { result in
        switch result {
        case .success:
          Log.info(#file, "✅ Token refresh successful - re-fetching manifest with fresh token")
          
          fetchOpenAccessManifest(for: book) { json in
            guard let json else {
              Log.error(#file, "❌ Failed to re-fetch manifest after token refresh")
              openingBooks.remove(book.identifier)
              showAudiobookTryAgainError()
              onFinish?()
              return
            }
            
            Log.info(#file, "✅ Manifest re-fetched with fresh bearer token - opening audiobook")
            presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
          }
          
        case .failure(let error):
          Log.error(#file, "❌ Token refresh failed: \(error.localizedDescription) - cannot open audiobook")
          openingBooks.remove(book.identifier)
          showAudiobookTryAgainError()
          onFinish?()
        }
      }
      return
    }
    
    // For non-audiobooks or valid tokens, proceed normally
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
    Log.debug(#file, "🎵 [AUDIOBOOK] Attempting to present audiobook: \(book.title) (ID: \(book.identifier))")
    Log.debug(#file, "  Distributor: \(book.distributor ?? "nil")")
    
#if LCP
    Log.debug(#file, "  Checking LCP audiobook support...")
    if LCPAudiobooks.canOpenBook(book) {
      Log.debug(#file, "  ✅ LCP audiobook detected")
      
      if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier), FileManager.default.fileExists(atPath: localURL.path) {
        Log.debug(#file, "  → Using LOCAL LCP file: \(localURL.path)")
        buildAndPresentAudiobook(book: book, lcpSourceURL: localURL, onFinish: onFinish)
        return
      } else {
        Log.debug(#file, "  No local LCP file found")
      }
      
      if let license = licenseURL(forBookIdentifier: book.identifier) {
        Log.debug(#file, "  → Using LCP LICENSE file: \(license.path)")
        buildAndPresentAudiobook(book: book, lcpSourceURL: license, onFinish: onFinish)
        return
      } else {
        Log.debug(#file, "  No LCP license file found")
      }
    } else {
      Log.debug(#file, "  Not an LCP audiobook")
    }
#else
    Log.debug(#file, "  LCP not compiled in this build")
#endif

    Log.debug(#file, "  Checking for local audiobook manifest...")
    if let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier),
       FileManager.default.fileExists(atPath: url.path) {
      Log.debug(#file, "  Local file exists at: \(url.path)")
      
      guard let data = try? Data(contentsOf: url) else {
        Log.error(#file, "  ❌ Failed to read local file data")
        showAudiobookTryAgainError()
        openingBooks.remove(book.identifier)
        onFinish?()
        return
      }
      
      guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        Log.error(#file, "  ❌ Failed to parse local file as JSON")
        showAudiobookTryAgainError()
        openingBooks.remove(book.identifier)
        onFinish?()
        return
      }
      
      Log.debug(#file, "  ✅ Successfully parsed local manifest JSON")
      presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
      return
    } else {
      Log.debug(#file, "  No local audiobook file found")
    }

    Log.debug(#file, "  → Fetching open access manifest from network...")
    fetchOpenAccessManifest(for: book) { json in
      guard let json else {
        Log.error(#file, "  ❌ Failed to fetch or parse open access manifest")
        showAudiobookTryAgainError()
        openingBooks.remove(book.identifier)
        onFinish?()
        return
      }
      Log.debug(#file, "  ✅ Successfully fetched and parsed open access manifest")
      presentAudiobookFrom(book: book, json: json, decryptor: nil, onFinish: onFinish)
    }
  }

#if LCP
  private static func buildAndPresentAudiobook(book: TPPBook, lcpSourceURL: URL, onFinish: (() -> Void)?) {
    Log.debug(#file, "🔐 [LCP AUDIOBOOK] Building LCP-protected audiobook")
    Log.debug(#file, "  LCP source: \(lcpSourceURL.path)")
    
    guard let lcpAudiobooks = LCPAudiobooks(for: lcpSourceURL) else {
      Log.error(#file, "  ❌ Failed to create LCPAudiobooks instance from URL")
      Log.error(#file, "    This could indicate license parsing failure or invalid LCP file")
      showAudiobookTryAgainError()
      openingBooks.remove(book.identifier)
      onFinish?()
      return
    }
    
    Log.debug(#file, "  ✅ LCPAudiobooks instance created")
    
    if let cached = lcpAudiobooks.cachedContentDictionary() as? [String: Any] {
      Log.debug(#file, "  → Using CACHED content dictionary from LCP")
      presentAudiobookFrom(book: book, json: cached, decryptor: lcpAudiobooks, onFinish: onFinish)
      return
    }
    
    Log.debug(#file, "  → Fetching content dictionary from LCP...")
    lcpAudiobooks.contentDictionary { dict, error in
      Task { @MainActor in
        if let error = error {
          Log.error(#file, "  ❌ Error fetching LCP content dictionary: \(error.localizedDescription)")
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        guard let json = dict as? [String: Any] else {
          Log.error(#file, "  ❌ LCP content dictionary is not a valid JSON dictionary")
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        Log.debug(#file, "  ✅ Successfully retrieved LCP content dictionary")
        Log.debug(#file, "    Dictionary keys: \(json.keys.joined(separator: ", "))")
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
    Log.debug(#file, "🏗️ [AUDIOBOOK FACTORY] Building audiobook from manifest")
    Log.debug(#file, "  Book: \(book.title) (ID: \(book.identifier))")
    Log.debug(#file, "  Has decryptor: \(decryptor != nil)")
    Log.debug(#file, "  Has bearer token: \(book.bearerToken != nil)")
    
    var jsonDict = json
    jsonDict["id"] = book.identifier

    let vendorCompletion: (Foundation.NSError?) -> Void = { (error: Foundation.NSError?) in
      Task { @MainActor in
        if let error = error {
          Log.error(#file, "  ❌ Vendor completion failed with error: \(error.localizedDescription)")
          Log.error(#file, "    Domain: \(error.domain), Code: \(error.code)")
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }

        Log.debug(#file, "  Creating audiobook with bearerToken: '\(book.bearerToken ?? "nil")'")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: []) else {
          Log.error(#file, "  ❌ Failed to serialize JSON dictionary to Data")
          Log.error(#file, "    JSON keys: \(jsonDict.keys.joined(separator: ", "))")
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        Log.debug(#file, "  JSON data size: \(jsonData.count) bytes")
        
        let manifest: Manifest
        do {
          manifest = try Manifest.customDecoder().decode(Manifest.self, from: jsonData)
        } catch {
          Log.error(#file, "  ❌ Failed to decode Manifest from JSON")
          Log.error(#file, "    Decoding error: \(error)")
          
          if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
              Log.error(#file, "    Missing key: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
            case .typeMismatch(let type, let context):
              Log.error(#file, "    Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
              Log.error(#file, "    Debug description: \(context.debugDescription)")
            case .valueNotFound(let type, let context):
              Log.error(#file, "    Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
            case .dataCorrupted(let context):
              Log.error(#file, "    Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " → "))")
              Log.error(#file, "    Description: \(context.debugDescription)")
            @unknown default:
              Log.error(#file, "    Unknown decoding error")
            }
          }
          
          if let jsonString = String(data: jsonData, encoding: .utf8) {
            Log.error(#file, "    Full manifest JSON: \(jsonString)")
          }
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        Log.debug(#file, "  ✅ Manifest decoded successfully")
        Log.debug(#file, "    Manifest metadata: \(manifest.metadata?.title ?? "no title")")
        
        guard let audiobook = AudiobookFactory.audiobook(
          for: manifest,
          bookIdentifier: book.identifier,
          decryptor: decryptor,
          token: book.bearerToken
        ) else {
          Log.error(#file, "  ❌ AudiobookFactory failed to create audiobook")
          Log.error(#file, "    This likely means no suitable player could be created for this manifest")
          Log.error(#file, "    Manifest type: \(manifest.metadata?.type ?? "unknown")")
          showAudiobookTryAgainError()
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        Log.debug(#file, "  ✅ Audiobook created successfully by factory")

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
        
        // Notify CarPlay and other observers that an audiobook manager was created
        AudiobookEvents.managerCreated.send(manager)

        let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book)
        manager.bookmarkDelegate = bookmarkLogic
        
        manager.playbackCompletionHandler = { [weak book, weak manager] in
          guard let book = book, let manager = manager else { return }
          
          // Save beginning position immediately (book just finished)
          if let firstTrack = manager.audiobook.tableOfContents.allTracks.first {
            let beginningPosition = TrackPosition(
              track: firstTrack,
              timestamp: 0.0,
              tracks: manager.audiobook.tableOfContents.tracks
            )
            manager.saveLocation(beginningPosition)
          }
          
          // Show the keep or return dialog
          BookDetailViewModel.presentEndOfBookAlert(for: book)
        }

        let playbackModel = AudiobookPlaybackModel(audiobookManager: manager)
        
        // Update cover image through both playback model and session manager
        // Session manager coordinates Now Playing info centrally
        if let cover = book.coverImage {
          playbackModel.updateCoverImage(cover)
          AudiobookSessionManager.shared.updateCoverImage(cover)
        } else {
          Task {
            if let img = await TPPBookCoverRegistry.shared.coverImage(for: book) {
              await MainActor.run {
                playbackModel.updateCoverImage(img)
                AudiobookSessionManager.shared.updateCoverImage(img)
              }
            }
          }
        }

        // Present the AudiobookPlayerView and start playback
        // Note: For CarPlay, coordinator may be nil - that's OK, we still start playback
        let route = BookRoute(id: book.identifier)
        
        if let coordinator = NavigationCoordinatorHub.shared.coordinator {
          Log.debug(#file, "  🎉 Successfully presenting audiobook player to user")
          coordinator.storeAudioModel(playbackModel, forBookId: route.id)
          // Use pushAudioRoute to clear any existing audio routes first (prevents stack accumulation)
          coordinator.pushAudioRoute(route)
        } else {
          Log.info(#file, "  📱 No coordinator available (CarPlay background launch?) - proceeding with playback only")
        }
        
        // Get local position IMMEDIATELY for fast startup
        let shouldRestorePosition = shouldRestoreBookmarkPosition(for: book)
        let localPosition = shouldRestorePosition ? getValidLocalPosition(book: book, audiobook: audiobook) : nil
        
        // Determine initial position - use local or start from beginning
        let initialPosition: TrackPosition
        if let local = localPosition {
          Log.debug(#file, "Starting playback immediately with local position: track=\(local.track.key), timestamp=\(local.timestamp)")
          initialPosition = local
        } else if let firstTrack = audiobook.tableOfContents.allTracks.first {
          Log.debug(#file, "Starting \(book.title) from beginning - no saved position")
          initialPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobook.tableOfContents.tracks)
        } else {
          Log.error(#file, "No tracks available in audiobook")
          openingBooks.remove(book.identifier)
          onFinish?()
          return
        }
        
        // START PLAYBACK IMMEDIATELY - don't wait for remote sync
        Task { @MainActor in
          playbackModel.currentLocation = initialPosition
          playbackModel.beginSaveSuppression(for: 3.0)
          manager.audiobook.player.play(at: initialPosition) { error in
            if let error = error {
              Log.error(#file, "Playback start error: \(error)")
            } else {
              Log.info(#file, "🎵 Playback started immediately at local position")
            }
          }
        }
        
        // Sync remote position ASYNCHRONOUSLY - update playback if remote is newer
        TPPBookRegistry.shared.syncLocation(for: book) { [weak playbackModel, weak manager] (remoteBookmark: AudioBookmark?) in
          guard let playbackModel = playbackModel, let manager = manager else { return }
          
          // Check if remote position is newer than what we started with
          guard let remoteBookmark = remoteBookmark,
                let remote = TrackPosition(
                  audioBookmark: remoteBookmark,
                  toc: audiobook.tableOfContents.toc,
                  tracks: audiobook.tableOfContents.tracks
                ) else {
            Log.debug(#file, "No remote position found - continuing with local position")
            return
          }
          
          // Compare timestamps to see if remote is newer
          let formatter = ISO8601DateFormatter()
          let localSaveDate = localPosition.flatMap { formatter.date(from: $0.lastSavedTimeStamp) }
          let remoteSaveDate = formatter.date(from: remote.lastSavedTimeStamp)
          
          // Only seek to remote if it's significantly newer (more than 5 seconds difference)
          // to avoid unnecessary seeks during normal playback
          if let remoteDate = remoteSaveDate {
            let shouldUseRemote: Bool
            if let localDate = localSaveDate {
              shouldUseRemote = remoteDate.timeIntervalSince(localDate) > 5.0
            } else {
              shouldUseRemote = true
            }
            
            if shouldUseRemote {
              Log.info(#file, "📡 Remote position is newer - seeking to remote: track=\(remote.track.key), timestamp=\(remote.timestamp)")
              Task { @MainActor in
                playbackModel.currentLocation = remote
                manager.audiobook.player.play(at: remote) { error in
                  if let error = error {
                    Log.error(#file, "Failed to seek to remote position: \(error)")
                  }
                }
              }
            } else {
              Log.debug(#file, "Local position is current - keeping local position")
            }
          }
        }
        
        // Save initial position after suppression period ends
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
          playbackModel.persistLocation()
        }

        openingBooks.remove(book.identifier)
        onFinish?()
      }
    }

    AudioBookVendorsHelper.updateVendorKey(book: jsonDict) { error in
      Task { @MainActor in
        vendorCompletion(error)
      }
    }
  }

  private static func fetchOpenAccessManifest(for book: TPPBook, completion: @escaping ([String: Any]?) -> Void) {
    guard let url = book.defaultAcquisition?.hrefURL else {
      Log.error(#file, "  ❌ No default acquisition URL for fetching manifest")
      Log.error(#file, "    Book: \(book.title) (ID: \(book.identifier))")
      Log.error(#file, "    Default acquisition: \(book.defaultAcquisition?.type ?? "nil")")
      completion(nil)
      return
    }
    
    Log.debug(#file, "  📡 Fetching manifest from URL: \(url.absoluteString)")
    
    let task = TPPNetworkExecutor.shared.download(url) { data, response, error in
      if let error = error {
        Log.error(#file, "  ❌ Network error fetching manifest: \(error.localizedDescription)")
        completion(nil)
        return
      }
      
      guard let data = data else {
        Log.error(#file, "  ❌ No data received from manifest fetch")
        completion(nil)
        return
      }
      
      Log.debug(#file, "  ✅ Received \(data.count) bytes of manifest data")
      
      if let httpResponse = response as? HTTPURLResponse {
        Log.debug(#file, "    HTTP status: \(httpResponse.statusCode)")
        Log.debug(#file, "    Content-Type: \(httpResponse.allHeaderFields["Content-Type"] ?? "unknown")")
      }
      
      guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
        Log.error(#file, "  ❌ Failed to parse manifest data as JSON dictionary")
        if let dataString = String(data: data, encoding: .utf8) {
          Log.error(#file, "    Data preview: \(String(dataString.prefix(200)))...")
        }
        completion(nil)
        return
      }
      
      Log.debug(#file, "  ✅ Successfully parsed manifest JSON")
      Log.debug(#file, "    JSON keys: \(json.keys.joined(separator: ", "))")
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
    
    Log.debug(#file, "Position check for \(book.title): state=\(bookState), hasLocation=\(hasLocation)")
    
    // If there's no saved location, always start from beginning
    guard hasLocation else {
      Log.debug(#file, "No saved location found - starting from beginning")
      return false
    }
    
    // Always restore saved positions unless explicitly a new download
    if bookState == .downloadSuccessful {
      // Even for newly downloaded books, restore position if one exists
      // This handles cases where user previously started reading
      Log.debug(#file, "Book is downloadSuccessful but has saved location - restoring position")
      return true
    }
    
    Log.debug(#file, "Restoring saved position for book")
    return true
  }
  
  /// Gets valid local position if available
  private static func getValidLocalPosition(book: TPPBook, audiobook: Audiobook) -> TrackPosition? {
    guard let dict = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.locationStringDictionary(),
          let localBookmark = AudioBookmark.create(locatorData: dict),
          let localPosition = TrackPosition(
            audioBookmark: localBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
          ),
          isValidPosition(localPosition, in: audiobook.tableOfContents) else {
      return nil
    }
    return localPosition
  }
  
  /// Validates that a position is reasonable and not corrupted
  private static func isValidPosition(_ position: TrackPosition, in tableOfContents: AudiobookTableOfContents) -> Bool {
    Log.debug(#file, "Validating position: track=\(position.track.index), timestamp=\(position.timestamp)")
    
    // Check if position is within reasonable bounds
    guard position.timestamp >= 0 && position.timestamp.isFinite else {
      Log.warn(#file, "Invalid position timestamp: \(position.timestamp)")
      return false
    }
    
    // Check if track exists in table of contents
    guard tableOfContents.tracks.track(forKey: position.track.key) != nil else {
      Log.warn(#file, "Position references non-existent track: \(position.track.key)")
      return false
    }
    
    // Check if position is within reasonable bounds (basic validation)
    let totalDuration = tableOfContents.tracks.totalDuration
    let positionDuration = position.durationToSelf()
    
    // FIXED: If durations aren't available yet (common for Overdrive), skip validation
    if totalDuration <= 0 {
      Log.debug(#file, "Position validation: Total duration not available yet, accepting position")
      return true
    }
    
    let percentageThrough = positionDuration / totalDuration
    
    Log.debug(#file, "Position validation: \(Int(percentageThrough * 100))% through book")
    
    // More lenient validation - only reject if position is clearly invalid
    if positionDuration > totalDuration * 1.1 { // Allow 10% overflow for timing variations
      Log.warn(#file, "Position is beyond book duration (\(Int(percentageThrough * 100))%), starting from beginning")
      return false
    }
    
    Log.debug(#file, "Position validation passed")
    return true
  }
  
  /// Gets download date for a book (placeholder - would integrate with download tracking)
  private static func getDownloadDate(for bookId: String) -> Date? {
    // This would integrate with MyBooksDownloadCenter to get actual download date
    // For now, return nil to be conservative
    return nil
  }



  private static func showAudiobookTryAgainError() {
    Log.warn(#file, "⚠️ [ERROR ALERT] Showing 'An error was encountered while trying to open this book' alert to user")
    
    // Log the error so it can be captured by enhanced logging
    let error = NSError(
      domain: "AudiobookOpenError",
      code: TPPErrorCode.audiobookCorrupted.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Failed to open audiobook",
        "error_type": "audiobook_open_failure"
      ]
    )
    
    TPPErrorLogger.logError(
      error,
      summary: "Audiobook failed to open - showing try again error",
      metadata: [
        "user_message": Strings.Error.tryAgain
      ]
    )
    
    let alert = TPPAlertUtils.alert(title: Strings.Error.openFailedError, message: Strings.Error.tryAgain)
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}


