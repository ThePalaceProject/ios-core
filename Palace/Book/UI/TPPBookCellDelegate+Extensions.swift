//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

let kTimerInterval: Double = 5.0

private struct AssociatedKeys {
  static var audiobookBookmarkBusinessLogic = "audiobookBookmarkBusinessLogic"
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
  
  public func openAudiobook(withBook book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?, completion: (() -> Void)?) {
    AudioBookVendorsHelper.updateVendorKey(book: json) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        
        if let error = error {
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
        
        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        let audiobookManager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks))
        
        self.audiobookBookmarkBusinessLogic = AudiobookBookmarkBusinessLogic(book: book)
        audiobookManager.bookmarkDelegate = self.audiobookBookmarkBusinessLogic
        
        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager)
        
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
        
        self.startLoading(audiobookPlayer)
        
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
//  public func scheduleTimer(forAudiobook book: TPPBook, manager: DefaultAudiobookManager, viewController: UIViewController) {
//    self.lastServerUpdate = Date()
//    self.audiobookViewController = viewController
//    self.manager = manager
//    self.book = book
//    
//    timer?.cancel()
//    timer = nil
//    
//    let queue = DispatchQueue(label: "com.palace.pollAudiobookLocation", qos: .background, attributes: .concurrent)
//    timer = DispatchSource.makeTimerSource(queue: queue)
//    
//    timer?.schedule(deadline: .now() + kTimerInterval, repeating: kTimerInterval)
//    
//    timer?.setEventHandler { [weak self] in
//      self?.pollAudiobookReadingLocation()
//    }
//    
//    timer?.resume()
//  }
  public func scheduleTimer(forAudiobook book: TPPBook, manager: DefaultAudiobookManager, viewController: UIViewController) {
    self.lastServerUpdate = Date()
    self.audiobookViewController = viewController
    self.manager = manager
    self.book = book
    
    // Cancel any previous timer
    timer?.cancel()
    timer = nil
    
    let queue = DispatchQueue(label: "com.palace.pollAudiobookLocation", qos: .background, attributes: .concurrent)
    timer = DispatchSource.makeTimerSource(queue: queue)
    
    // Start the timer
    timer?.schedule(deadline: .now() + kTimerInterval, repeating: kTimerInterval)
    
    timer?.setEventHandler { [weak self] in
      self?.pollAudiobookReadingLocation()
    }
    
    timer?.resume()
    
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(applicationDidEnterBackground),
                                           name: UIApplication.didEnterBackgroundNotification,
                                           object: nil)
    
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(applicationWillEnterForeground),
                                           name: UIApplication.willEnterForegroundNotification,
                                           object: nil)
  }
  
  @objc private func applicationDidEnterBackground() {
    timer?.suspend()
  }
  
  @objc private func applicationWillEnterForeground() {
    timer?.resume()
  }

  @objc public func pollAudiobookReadingLocation() {
    DispatchQueue.main.async {
      guard UIApplication.shared.applicationState == .active else {
        return
      }
      
      guard let _ = self.audiobookViewController else {
        timer?.cancel()
        timer = nil
        self.manager = nil
        return
      }
      
      guard let currentTrackPosition = self.manager?.audiobook.player.currentTrackPosition else {
        return
      }
      
      let playheadOffset = currentTrackPosition.timestamp
      if self.previousPlayheadOffset != playheadOffset && playheadOffset > 0 {
        self.previousPlayheadOffset = playheadOffset
        
        DispatchQueue.global(qos: .background).async { [weak self] in
          guard let self = self else { return }
          
          let locationData = try? JSONEncoder().encode(currentTrackPosition.toAudioBookmark())
          let locationString = String(data: locationData ?? Data(), encoding: .utf8) ?? ""
          
          TPPBookRegistry.shared.setLocation(TPPBookLocation(locationString: locationString, renderer: "PalaceAudiobookToolkit"), forIdentifier: self.book.identifier)
          latestAudiobookLocation = (book: self.book.identifier, location: locationString)
        }
      }
    }
  }
}
