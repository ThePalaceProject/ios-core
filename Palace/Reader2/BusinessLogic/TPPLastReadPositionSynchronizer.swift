//
//  TPPLastReadPositionSynchronizer.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

/// A front-end to the Annotations api to sync the reading progress for
/// a given book with the progress on the server.
class TPPLastReadPositionSynchronizer {
  typealias DisplayStrings = Strings.TPPLastReadPositionSynchronizer

  private let bookRegistry: TPPBookRegistryProvider

  /// Designated initializer.
  ///
  /// - Parameters:
  ///   - bookRegistry: The registry that stores the reading progresses.
  init(bookRegistry: TPPBookRegistryProvider) {
    self.bookRegistry = bookRegistry
  }

  /// Fetches the read position from the server and alerts the user
  /// if it differs from the local position or if it comes from a
  /// different device.
  ///
  /// Before the `completion` closure is called, the `bookRegistry` is going
  /// to be updated with the correct progress location, if needed.
  ///
  /// - Parameters:
  ///   - publication: The R2 publication associated with the current `book`.
  ///   - book: The book whose position needs syncing.
  ///   - drmDeviceID: The device ID is used to identify if the last read
  ///   position retrieved from the server was from a different device.
  ///   - completion: Called when syncing is complete.
  func sync(for publication: Publication,
            book: TPPBook,
            drmDeviceID: String?,
            completion: @escaping () -> Void) {

    syncReadPosition(for: book, drmDeviceID: drmDeviceID) { serverLocator in
      TPPMainThreadRun.asyncIfNeeded {
        if let serverLocator = serverLocator {
          self.presentNavigationAlert(for: serverLocator,
                                      publication: publication,
                                      book: book,
                                      completion: completion)
        } else {
          completion()
        }
      }
    }
  }

  // MARK:- Private methods

  /// Fetch the read position from the server and return it to the client
  /// if it differs from the local position or if it comes from a
  /// different device.
  ///
  /// - Parameters:
  ///   - book: The book whose position needs syncing.
  ///   - drmDeviceID: The device ID is used to identify if the last read
  ///   position retrieved from the server was from a different device.
  ///   - completion: always called at the end of the sync process. If the
  ///   server finds a different last read location on another device, this
  ///   completion will return that position, and `nil` in all other case.
  ///   This closure is not retained by `self`.
  private func syncReadPosition(for book: TPPBook,
                                drmDeviceID: String?,
                                completion: @escaping (Locator?) -> ()) {

    let localLocation = bookRegistry.location(forIdentifier: book.identifier)

    TPPAnnotations
      .syncReadingPosition(ofBook: book.identifier, toURL: book.annotationsURL) { bookmark in

        guard let bookmark = bookmark else {
          Log.info(#function, "No reading position annotation exists on the server for \(book.loggableShortString()).")
          completion(nil)
          return
        }

        guard let bookmark = bookmark as? TPPReadiumBookmark else {
          completion(nil)
          return
        }

        let deviceID = bookmark.device ?? ""
        let serverLocationString = bookmark.location

        // Pass through returning nil (meaning the server doesn't have a
        // last read location worth restoring) if:
        // 1 - The most recent page on the server comes from the same device, or
        // 2 - The server and the client have the same page marked
        if deviceID == drmDeviceID
          || localLocation?.locationString == serverLocationString {

          // server location does not differ from or should take no precedence
          // over the local position
          completion(nil)
          return
        }

        // we got a server location that differs from the local: return that
        // so that clients can decide what to do
        let bookLocation = TPPBookLocation(locationString: serverLocationString,
                                            renderer: TPPBookLocation.r2Renderer)
        completion(bookLocation?.convertToLocator())
    }
  }

  private func presentNavigationAlert(for serverLocator: Locator,
                                      publication: Publication,
                                      book: TPPBook,
                                      completion: @escaping () -> Void) {
    let alert = UIAlertController(title: DisplayStrings.syncReadingPositionAlertTitle,
                                  message: DisplayStrings.syncReadingPositionAlertBody,
                                  preferredStyle: .alert)

    let stayText = DisplayStrings.stay
    let stayAction = UIAlertAction(title: stayText, style: .cancel) { _ in
      completion()
    }

    let moveText = DisplayStrings.move
    let moveAction = UIAlertAction(title: moveText, style: .default) { _ in
      let loc = TPPBookLocation(locator: serverLocator,
                                type: "LocatorHrefProgression",
                                 publication: publication)
      self.bookRegistry.setLocation(loc, forIdentifier: book.identifier)
      completion()
    }

    alert.addAction(stayAction)
    alert.addAction(moveAction)

    TPPPresentationUtils.safelyPresent(alert)
  }

}
