//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceAudiobookToolkit
import Combine

let kTimerInterval: Double = 5.0


private struct AssociatedKeys {
  static var audiobookBookmarkBusinessLogic: UInt8 = 0
  static var playbackLoadingCancellable: UInt8 = 0
}

private let locationQueue = DispatchQueue(label: "com.palace.latestAudiobookLocation", attributes: .concurrent)
private var _latestAudiobookLocation: (book: String, location: String)?
private var timer: DispatchSourceTimer?

var latestAudiobookLocation: (book: String, location: String)? {
  get {
    locationQueue.sync {
      _latestAudiobookLocation
    }
  }
  set {
    locationQueue.async(flags: .barrier) {
      _latestAudiobookLocation = newValue
    }
  }
}

extension TPPBookCellDelegate {
  public func postListeningPosition(at location: String, completion: ((_ response: AnnotationResponse?) -> Void)? = nil) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
}

@objc extension TPPBookCellDelegate {
  private var audiobookBookmarkBusinessLogic: AudiobookBookmarkBusinessLogic? {
    get {
      return objc_getAssociatedObject(self, &AssociatedKeys.audiobookBookmarkBusinessLogic) as? AudiobookBookmarkBusinessLogic
    }
    set {
      objc_setAssociatedObject(
        self,
        &AssociatedKeys.audiobookBookmarkBusinessLogic,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }
  
  // MARK: - Main Audiobook Opening Entry Point
  
  @objc func openAudiobookWithUnifiedStreaming(_ book: TPPBook, completion: (() -> Void)? = nil) {
    // Consolidated presentation through BookOpenService + NavigationCoordinator
    BookOpenService.open(book)
    completion?()
  }
  
  private func openLocalLCPAudiobook(book: TPPBook, localURL: URL, completion: (() -> Void)?) {
#if LCP
    guard let lcpAudiobooks = LCPAudiobooks(for: localURL) else {
      self.presentUnsupportedItemError()
      completion?()
      return
    }
    
    lcpAudiobooks.contentDictionary { [weak self] dict, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let _ = error {
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        guard let dict else {
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        var jsonDict = dict as? [String: Any] ?? [:]
        jsonDict["id"] = book.identifier
        self.openAudiobook(withBook: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
      }
    }
#endif
  }
  
  private func getLCPLicenseURL(for book: TPPBook) -> URL? {
#if LCP
    guard let bookFileURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier) else {
      return nil
    }
    
    let licenseURL = bookFileURL.deletingPathExtension().appendingPathExtension("lcpl")
    
    if FileManager.default.fileExists(atPath: licenseURL.path) {
      return licenseURL
    }
#endif
    return nil
  }
  
  private func openAudiobookUnified(book: TPPBook, licenseUrl: URL, completion: (() -> Void)?) {
#if LCP
    if let localURL = MyBooksDownloadCenter.shared.fileUrl(for: book.identifier),
       FileManager.default.fileExists(atPath: localURL.path),
       licenseUrl.path == localURL.path {
      guard let lcpAudiobooks = LCPAudiobooks(for: localURL) else {
        self.presentUnsupportedItemError()
        completion?()
        return
      }
      
      lcpAudiobooks.contentDictionary { [weak self] dict, error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if let _ = error {
            self.presentUnsupportedItemError()
            completion?()
            return
          }
          guard let dict else {
            self.presentUnsupportedItemError()
            completion?()
            return
          }
          var jsonDict = dict as? [String: Any] ?? [:]
          jsonDict["id"] = book.identifier
          self.openAudiobook(withBook: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
        }
      }
      return
    }
    
    guard let lcpAudiobooks = LCPAudiobooks(for: licenseUrl) else {
      self.presentUnsupportedItemError()
      completion?()
      return
    }
    
    if let cachedDict = lcpAudiobooks.cachedContentDictionary() {
      var jsonDict = cachedDict as? [String: Any] ?? [:]
      jsonDict["id"] = book.identifier
      self.openAudiobook(withBook: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
      return
    }

    lcpAudiobooks.contentDictionary { [weak self] dict, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let _ = error {
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        guard let dict else {
          self.presentUnsupportedItemError()
          completion?()
          return
        }
        var jsonDict = dict as? [String: Any] ?? [:]
        jsonDict["id"] = book.identifier
        self.openAudiobook(withBook: book, json: jsonDict, drmDecryptor: lcpAudiobooks, completion: completion)
      }
    }
#endif
  }

  @objc public func openAudiobook(withBook book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?, completion: (() -> Void)?) {
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
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks, decryptor: drmDecryptor),
          playbackTrackerDelegate: timeTracker
        )

        self.audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
        audiobookManager.bookmarkDelegate = self.audiobookBookmarkBusinessLogic

        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager, coverImagePublisher: book.$coverImage.eraseToAnyPublisher())

        // Present the player UI in a full-screen navigation stack
        let nav = UINavigationController(rootViewController: audiobookPlayer)
        nav.modalPresentationStyle = .fullScreen
        TPPPresentationUtils.safelyPresent(nav, animated: true, completion: nil)

        defer {
          self.scheduleTimer(forAudiobook: book, manager: audiobookManager, viewController: audiobookPlayer)
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
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
          } else {
            TPPAppStoreReviewPrompt.presentIfAvailable()
          }
        }

        // Present via coordinator in Swift; legacy push removed in migration

        self.startLoading(audiobookPlayer)

        let cancellable = audiobookManager.audiobook.player.playbackStatePublisher
          .receive(on: DispatchQueue.main)
          .sink { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .started(_), .failed(_, _), .stopped(_):
              self.stopLoading()
            default:
              break
            }
          }
        objc_setAssociatedObject(self, &AssociatedKeys.playbackLoadingCancellable, cancellable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let localAudiobookLocation = TPPBookRegistry.shared.location(forIdentifier: book.identifier)

        guard let dictionary = localAudiobookLocation?.locationStringDictionary(),
              let localBookmark = AudioBookmark.create(locatorData: dictionary),
              let localPosition = TrackPosition(
                audioBookmark: localBookmark,
                toc: audiobook.tableOfContents.toc,
                tracks: audiobook.tableOfContents.tracks
              ) else {
          self.stopLoading()
          return
        }

        func moveCompletionHandler(_ error: Error?) {
          if let error = error {
            self.presentLocationRecoveryError(error)
            return
          }
          self.stopLoading()
        }

        audiobookManager.audiobook.player.play(at: localPosition) { error in
          moveCompletionHandler(error)
          self.stopLoading()
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

  @objc func presentDRMKeyError(_ error: Error) {
    let title = NSLocalizedString("DRM Error", comment: "")
    let message = error.localizedDescription
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }

  @objc func presentUnsupportedItemError() {
    let title = NSLocalizedString("Unsupported Item", comment: "")
    let message = NSLocalizedString("The item you are trying to open is not currently supported.", comment: "")
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true) {
      self.stopLoading()
    }
  }
}


public extension TPPBookCellDelegate {
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

  func requestSyncWithCompletion(completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.async {
      let title = LocalizedStrings.syncListeningPositionAlertTitle
      let message = LocalizedStrings.syncListeningPositionAlertBody
      let moveTitle = LocalizedStrings.move
      let stayTitle = LocalizedStrings.stay

      let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

      let moveAction = UIAlertAction(title: moveTitle, style: .default) { _ in
        completion(true)
      }

      let stayAction = UIAlertAction(title: stayTitle, style: .cancel) { _ in
        completion(false)
      }

      alertController.addAction(moveAction)
      alertController.addAction(stayAction)

      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
    }
  }
}

extension TPPBookCellDelegate {

  public func scheduleTimer(forAudiobook book: TPPBook, manager: DefaultAudiobookManager, viewController: UIViewController) {
    timer?.cancel()
    timer = nil

    self.audiobookViewController = viewController
    self.manager = manager
    self.book = book

    let queue = DispatchQueue(label: "com.palace.pollAudiobookLocation", qos: .background, attributes: .concurrent)
    timer = DispatchSource.makeTimerSource(queue: queue)

    timer?.schedule(deadline: .now() + kTimerInterval, repeating: kTimerInterval)

    timer?.setEventHandler { [weak self] in
      self?.pollAudiobookReadingLocation()
    }

    timer?.resume()
  }

  @objc public func pollAudiobookReadingLocation() {
    guard let manager = self.manager, let bookID = self.book?.identifier else {
      cancelTimer()
      return
    }

    guard let currentTrackPosition = manager.audiobook.player.currentTrackPosition else {
      return
    }

    let playheadOffset = currentTrackPosition.timestamp
    if self.previousPlayheadOffset != playheadOffset && playheadOffset > 0 {
      self.previousPlayheadOffset = playheadOffset

      DispatchQueue.global(qos: .background).async { [weak self] in
        guard let self = self else { return }

        let locationData = try? JSONEncoder().encode(currentTrackPosition.toAudioBookmark())
        let locationString = String(data: locationData ?? Data(), encoding: .utf8) ?? ""

        DispatchQueue.main.async {
          TPPBookRegistry.shared.setLocation(
            TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit"),
            forIdentifier: bookID
          )
          latestAudiobookLocation = (book: bookID, location: locationString)
        }
      }
    }
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
    self.manager = nil
  }
}
