//
//  TPPBookCellDelegate+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 4/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

@objc extension TPPBookCellDelegate {
  public func postListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)? = nil) {
    TPPAnnotations.postListeningPosition(forBook: self.book.identifier, selectorValue: location, completion: completion)
  }
}

@objc extension TPPBookCellDelegate {
  public func openAudiobook(withBook book: TPPBook, json: [String: Any], drmDecryptor: DRMDecryptor?) {
    AudioBookVendorsHelper.updateVendorKey(book: json) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        
        if let error = error {
          self.presentDRMKeyError(error)
          return
        }

        let manifestDecoder = Manifest.customDecoder()
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let manifest = try? manifestDecoder.decode(Manifest.self, from: jsonData),
              let audiobook = AudiobookFactory.audiobook(for: manifest, bookIdentifier: book.identifier, decryptor: drmDecryptor, token: book.bearerToken)
        else {
          self.presentUnsupportedItemError()
          return
        }

//        let timeTracker = book.timeTrackingURL.map { AudiobookTimeTracker(libraryId: AccountsManager.shared.currentAccount?.uuid ?? "", bookId: book.identifier, timeTrackingUrl: $0) }
        
        let metadata = AudiobookMetadata(title: book.title, authors: [book.authors ?? ""])
        let audiobookManager = DefaultAudiobookManager(
          metadata: metadata,
          audiobook: audiobook,
          networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks))
        
        let audiobookPlayer = AudiobookPlayer(audiobookManager: audiobookManager)
        //        audiobookManager?.playbackCompletionHandler = {
//          // Handle playback completion here
//        }
        
        TPPRootTabBarController.shared().pushViewController(audiobookPlayer, animated: true)
        TPPBookRegistry.shared.coverImage(for: book) { image in
          if let image {
            audiobookPlayer.updateImage(image)
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
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
}
