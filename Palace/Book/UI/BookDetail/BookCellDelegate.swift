import SwiftUI
import Combine


extension BookDetailViewModel {

  func didSelectReturn(for book: TPPBook, completion: (() -> Void)?) {
    MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier, completion: completion)
  }

  func didSelectDownload(for book: TPPBook) {
    MyBooksDownloadCenter.shared.startDownload(for: book)
  }

  func didSelectRead(for book: TPPBook, completion: (() -> Void)?) {
#if FEATURE_DRM_CONNECTOR
    let user = TPPUserAccount.sharedAccount()

    guard user.hasCredentials() else {
      openBook(book, completion: completion)
      return
    }

    if user.hasAuthToken() {
      openBook(book, completion: completion)
      return
    }

    if let certificate = AdobeCertificate.defaultCertificate,
        !certificate.hasExpired,
        !NYPLADEPT.sharedInstance().isUserAuthorized(user.userID, withDevice: user.deviceID) {

      let reauthenticator = TPPReauthenticator()
      reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: true) {
        self.openBook(book, completion: completion)
      }
      return
    }

    openBook(book, completion: completion)

#else
    openBook(book, completion: completion)
#endif
  }

  func openBook(_ book: TPPBook, completion: (() -> Void)?) {
    TPPCirculationAnalytics.postEvent("open_book", withBook: book)

    switch book.defaultBookContentType {
    case .epub:
      presentEPUB(book)
    case .pdf:
      presentPDF(book)
    case .audiobook:
      openAudiobook(book, completion: completion)
    default:
      presentUnsupportedItemError()
    }
  }

  private func presentEPUB(_ book: TPPBook) {
    TPPRootTabBarController.shared().presentBook(book)
  }

  private func presentPDF(_ book: TPPBook) {
    guard let bookUrl = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else { return }
    let data = try? Data(contentsOf: bookUrl)

    let metadata = TPPPDFDocumentMetadata(with: book)
    let document = TPPPDFDocument(data: data ?? Data())

    let pdfViewController = TPPPDFViewController.create(document: document, metadata: metadata)
    TPPRootTabBarController.shared().pushViewController(pdfViewController, animated: true)
  }

  func openAudiobook(_ book: TPPBook, completion: (() -> Void)?) {
    guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else {
      presentCorruptedItemError(for: book)
      completion?()
      return
    }

#if LCP
    if LCPAudiobooks.canOpenBook(book) {
      let lcpAudiobooks = LCPAudiobooks(for: url)
      lcpAudiobooks?.contentDictionary { dict, error in
        DispatchQueue.main.async {
          if let error = error {
            self.presentUnsupportedItemError()
            completion?()
            return
          }

          guard var dict = dict else {
            self.presentCorruptedItemError(for: book)
            completion?()
            return
          }

          var mutableDict = dict as? [String: Any] ?? [:]
          mutableDict["id"] = book.identifier
          self.openAudiobook(with: book, json: mutableDict, drmDecryptor: lcpAudiobooks, completion: completion)
        }
      }
      return
    }
#endif

    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard var json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        presentUnsupportedItemError()
        completion?()
        return
      }

#if FEATURE_OVERDRIVE
      if book.distributor == OverdriveDistributorKey {
        json["id"] = book.identifier
      }
#endif

      openAudiobook(with: book, json: json, drmDecryptor: nil, completion: completion)
    } catch {
      presentCorruptedItemError(for: book)
      completion?()
    }
  }

//  private func openAudiobook(_ book: TPPBook, completion: (() -> Void)?) {
//    guard let url = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else {
//      presentCorruptedItemError(for: book)
//      completion?()
//      return
//    }
//
//#if LCP
//    if LCPAudiobooks.canOpenBook(book) {
//      let lcpAudiobook = LCPAudiobooks(for: url)
//      lcpAudiobook?.contentDictionary { [weak self] dict, error in
//        guard let self = self else { return }
//
//        if error != nil {
//          Log.debug("Failed to open audiobook with error: %@", error?.localizedDescription ?? "")
//          self.presentUnsupportedItemError()
//          completion?()
//          return
//        }
//
//        guard let originalDict = dict else {
//          self.presentCorruptedItemError(for: book)
//          completion?()
//          return
//        }
//
//        var mutableDict = originalDict as? [String: Any] ?? [:]
//        mutableDict["id"] = book.identifier
//        self.openAudiobook(withBook: book, json: mutableDict, drmDecryptor: lcpAudiobook, completion: completion)
//      }
//      return
//    }
//#endif
//
//    do {
//      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
//      let fileSize = attributes[.size] as? Int ?? 0
//      print("File Size:", fileSize, "bytes")
//    } catch {
//      print("❌ Error getting file attributes:", error.localizedDescription)
//    }
//
//    do {
//      let data = try Data(contentsOf: url, options: .mappedIfSafe)
//      print("Raw data string:", String(data: data, encoding: .utf8) ?? "Invalid UTF-8 data")
//
//      guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
//        presentUnsupportedItemError()
//        completion?()
//        return
//      }
//
//      var dict = json
//#if FEATURE_OVERDRIVE
//      if book.distributor == OverdriveDistributorKey {
//        dict["id"] = book.identifier
//      }
//#endif
//
//      openAudiobook(withBook: book, json: dict, drmDecryptor: nil, completion: completion)
//    } catch {
//      presentCorruptedItemError(for: book)
//      completion?()
//    }
//  }

  public func openAudiobook(withBook book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?, completion: (() -> Void)?) {
    AudioBookVendorsHelper.updateVendorKey(book: json) { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          self.presentDRMKeyError(error)
          completion?()
          return
        }

        let manifestDecoder = Manifest.customDecoder()

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let manifest = try? manifestDecoder.decode(Manifest.self, from: jsonData),
              let audiobook = AudiobookFactory.audiobook(for: manifest, bookIdentifier: book.identifier, decryptor: drmDecryptor, token: book.bearerToken)
        else {
          self.presentUnsupportedItemError()
          completion?()
          return
        }

        var timeTracker: AudiobookTimeTracker?
        if let libraryId = AccountsManager.shared.currentAccount?.uuid, let timeTrackingURL = book.timeTrackingURL {
          timeTracker = AudiobookTimeTracker(libraryId: libraryId, bookId: book.identifier, timeTrackingUrl: timeTrackingURL)
        }

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        let audiobookManager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks),
          playbackTrackerDelegate: timeTracker
        )

//        self.audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
//        audiobookManager.bookmarkDelegate = self.audiobookBookmarkBusinessLogic

        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager)

        defer {
          self.scheduleTimer(for: book, manager: audiobookManager, viewController: audiobookPlayer)
        }

        audiobookManager.playbackCompletionHandler = {
          let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(), allowedRelations:  [.borrow, .generic], acquisitions: book.acquisitions)
          if paths.count > 0 {
            let alert = TPPReturnPromptHelper.audiobookPrompt { returnWasChosen in
              if returnWasChosen {
                audiobookPlayer.navigationController?.popViewController(animated: true)
                self.didSelectReturn(for: book, completion: nil)
              }
              TPPAppStoreReviewPrompt.presentIfAvailable()
            }
            TPPRootTabBarController.shared().present(alert, animated: true, completion: nil)
          } else {
            TPPAppStoreReviewPrompt.presentIfAvailable()
          }
        }

        TPPRootTabBarController.shared().pushViewController(audiobookPlayer, animated: true)
        TPPBookRegistry.shared.coverImage(for: book) { image in
          if let image {
            audiobookPlayer.updateImage(image)
          }
        }

//        self.startLoading(audiobookPlayer)

        let localAudiobookLocation = TPPBookRegistry.shared.location(forIdentifier: book.identifier)

        guard let dictionary = localAudiobookLocation?.locationStringDictionary(),
              let localBookmark = AudioBookmark.create(locatorData: dictionary),
              let localPosition = TrackPosition(
                audioBookmark: localBookmark,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              ) else {
//          self.stopLoading()
          return
        }

        func moveCompletionHandler(_ error: Error?) {
          if let error = error {
//            self.presentLocationRecoveryError(error)
            return
          }
//          self.stopLoading()
        }

        audiobookManager.audiobook.player.play(at: localPosition) { error in
          moveCompletionHandler(error)
//          self.stopLoading()
        }

        TPPBookRegistry.shared.syncLocation(for: book) { remoteBookmark in
          guard let remoteBookmark else { return }
          let remotePosition = TrackPosition(
            audioBookmark: remoteBookmark,
            toc: audiobook.tableOfContents.toc,
            tracks: audiobook.tableOfContents.tracks
          )

          self.chooseLocalLocation(
            localPosition: localPosition,
            remotePosition: remotePosition,
            serverUpdateDelay: 300
          ) { position in

            DispatchQueue.main.async {
              Log.debug("Returning to Audiobook Position: %@", position.description)
              audiobookManager.audiobook.player.play(at: position) { error in
                moveCompletionHandler(error)
              }
            }
          }
        }
      }
    }
  }

  private func presentCorruptedItemError(for book: TPPBook) {
    let alert = UIAlertController(
      title: NSLocalizedString("Corrupted Audiobook", comment: ""),
      message: NSLocalizedString("The audiobook you are trying to open appears to be corrupted. Try downloading it again.", comment: ""),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }

  private func presentUnsupportedItemError() {
    let alert = UIAlertController(
      title: NSLocalizedString("Unsupported Item", comment: ""),
      message: NSLocalizedString("This item format is not supported.", comment: ""),
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}

extension BookDetailViewModel {
  func openAudiobook(with book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?, completion: (() -> Void)?) {
    AudioBookVendorsHelper.updateVendorKey(book: json) { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          self.presentDRMKeyError(error)
          completion?()
          return
        }

        let manifestDecoder = Manifest.customDecoder()
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let manifest = try? manifestDecoder.decode(Manifest.self, from: jsonData),
              let audiobook = AudiobookFactory.audiobook(
                for: manifest, bookIdentifier: book.identifier, decryptor: drmDecryptor, token: book.bearerToken
              ) else {
          self.presentUnsupportedItemError()
          completion?()
          return
        }

        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        let audiobookManager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
        )

        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager)

        defer {
          self.scheduleTimer(for: book, manager: audiobookManager, viewController: audiobookPlayer)
        }

        TPPRootTabBarController.shared().pushViewController(audiobookPlayer, animated: true)

        //        self.startLoading(audiobookPlayer)
        self.restoreListeningPosition(for: book, manager: audiobookManager)
      }
    }
  }
}

extension BookDetailViewModel {
  private func presentDRMKeyError(_ error: Error) {
    let alert = UIAlertController(title: "DRM Error", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }


  private func restoreListeningPosition(for book: TPPBook, manager: DefaultAudiobookManager) {
    let localLocation = TPPBookRegistry.shared.location(forIdentifier: book.identifier)

    guard let dictionary = localLocation?.locationStringDictionary(),
          let localBookmark = AudioBookmark.create(locatorData: dictionary),
          let localPosition = TrackPosition(audioBookmark: localBookmark, toc: manager.audiobook.tableOfContents.toc, tracks: manager.audiobook.tableOfContents.tracks) else {
      //      stopLoading()
      return
    }

    manager.audiobook.player.play(at: localPosition) { error in
      if let error = error {
        self.presentLocationRecoveryError(error)
      }
      //      self.stopLoading()
    }

    TPPBookRegistry.shared.syncLocation(for: book) { remoteBookmark in
      guard let remoteBookmark else { return }
      let remotePosition = TrackPosition(audioBookmark: remoteBookmark, toc: manager.audiobook.tableOfContents.toc, tracks: manager.audiobook.tableOfContents.tracks)

      self.chooseSyncLocation(localPosition: localPosition, remotePosition: remotePosition) { position in
        DispatchQueue.main.async {
          manager.audiobook.player.play(at: position) { error in
            if let error = error {
              self.presentLocationRecoveryError(error)
            }
          }
        }
      }
    }
  }

  private func presentLocationRecoveryError(_ error: Error) {
    let alert = UIAlertController(title: "Location Recovery Error", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}

extension BookDetailViewModel {
  func chooseSyncLocation(localPosition: TrackPosition?, remotePosition: TrackPosition?, operation: @escaping (TrackPosition) -> Void) {
    guard let remote = remotePosition, remote.description != localPosition?.description else {
      if let local = localPosition {
        operation(local)
      } else if let remote = remotePosition {
        operation(remote)
      }
      return
    }

    requestSyncWithCompletion { shouldSync in
      operation(shouldSync ? remote : (localPosition ?? remote))
    }
  }

  func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.async {
      let alertController = UIAlertController(title: "Sync Listening Position?", message: "Would you like to sync to the latest listening position?", preferredStyle: .alert)

      alertController.addAction(UIAlertAction(title: "Move to New Position", style: .default) { _ in completion(true) })
      alertController.addAction(UIAlertAction(title: "Stay at Current Position", style: .cancel) { _ in completion(false) })

      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
    }
  }
}

extension BookDetailViewModel {
  func scheduleTimer(for book: TPPBook, manager: DefaultAudiobookManager, viewController: UIViewController) {
//    self.audiobookViewController = viewController
//    self.audiobookManager = manager
//
//    timer?.cancel()
//    timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
//    timer?.schedule(deadline: .now() + 5, repeating: 5)
//    timer?.setEventHandler { [weak self] in self?.pollAudiobookReadingLocation() }
//    timer?.resume()
  }

  @objc private func pollAudiobookReadingLocation() {
//    DispatchQueue.main.async {
//      guard let self = self, let currentTrackPosition = self.audiobookManager?.audiobook.player.currentTrackPosition else { return }
//
//      let playheadOffset = currentTrackPosition.timestamp
//      if self.previousPlayheadOffset != playheadOffset && playheadOffset > 0 {
//        self.previousPlayheadOffset = playheadOffset
//        TPPBookRegistry.shared.setLocation(TPPBookLocation(locationString: playheadOffset.description, renderer: "PalaceAudiobookToolkit"), forIdentifier: self.book.identifier)
//      }
//    }
    
  }
}

extension BookDetailViewModel {
  func chooseLocalLocation(localPosition: TrackPosition?, remotePosition: TrackPosition?, serverUpdateDelay: TimeInterval, operation: @escaping (TrackPosition) -> Void) {
    let remoteLocationIsNewer: Bool

    if let localPosition = localPosition, let remotePosition = remotePosition {
      remoteLocationIsNewer = String.isDate(remotePosition.lastSavedTimeStamp, moreRecentThan: localPosition.lastSavedTimeStamp, with: serverUpdateDelay)
    } else {
      remoteLocationIsNewer = localPosition == nil && remotePosition != nil
    }

    if let remotePosition = remotePosition,
       remotePosition.description != localPosition?.description,
       remoteLocationIsNewer {
      requestSyncWithCompletion { shouldSync in
        let location = shouldSync ? remotePosition : (localPosition ?? remotePosition)
        operation(location)
      }
    } else if let localPosition = localPosition {
      operation(localPosition)
    } else if let remotePosition = remotePosition {
      operation(remotePosition)
    }
  }
}
