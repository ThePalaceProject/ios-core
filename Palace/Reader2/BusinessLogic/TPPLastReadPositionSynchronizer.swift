//
//  TPPLastReadPositionSynchronizer.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared

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
    Task {
      await sync(for: publication, book: book, drmDeviceID: drmDeviceID)
      TPPMainThreadRun.asyncIfNeeded {
        completion()
      }
    }
  }

  func sync(for publication: Publication,
            book: TPPBook,
            drmDeviceID: String?) async {
    let serverLocator = await syncReadPosition(for: book, drmDeviceID: drmDeviceID, publication: publication)

    if let serverLocator = serverLocator {
      await presentNavigationAlert(for: serverLocator,
                                   publication: publication,
                                   book: book)
    }
  }

  // MARK:- Private methods

  private func syncReadPosition(for book: TPPBook, drmDeviceID: String?, publication: Publication) async -> Locator? {
    let localLocation = bookRegistry.location(forIdentifier: book.identifier)

    guard let bookmark = await TPPAnnotations.syncReadingPosition(ofBook: book, toURL: TPPAnnotations.annotationsURL) else {
      Log.info(#function, "No reading position annotation exists on the server for \(book.loggableShortString()).")
      return nil
    }

    guard let bookmark = bookmark as? TPPReadiumBookmark else {
      return nil
    }

    let deviceID = bookmark.device ?? ""
    let serverLocationString = bookmark.location

    // Pass through returning nil (meaning the server doesn't have a
    // last read location worth restoring) if:
    // 1 - The most recent page on the server comes from the same device and there is no localLocation, or
    // 2 - The server and the client have the same page marked
    if (deviceID == drmDeviceID && localLocation != nil)
        || localLocation?.locationString == serverLocationString {

      // Server location does not differ from or should take no precedence
      // over the local position.
      return nil
    }

    // We got a server location that differs from the local: return that
    // so that clients can decide what to do.
    let bookLocation = TPPBookLocation(locationString: serverLocationString,
                                       renderer: TPPBookLocation.r3Renderer)
    return await bookLocation?.convertToLocator(publication: publication)
  }

  private func presentNavigationAlert(for serverLocator: Locator,
                                      publication: Publication,
                                      book: TPPBook,
                                      completion: @escaping () -> Void) {
    Task {
      await presentNavigationAlert(for: serverLocator, publication: publication, book: book)
      completion()
    }
  }

  /// Async version of `presentNavigationAlert`.
  private func presentNavigationAlert(for serverLocator: Locator,
                                      publication: Publication,
                                      book: TPPBook) async {
    await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: DisplayStrings.syncReadingPositionAlertTitle,
                                    message: DisplayStrings.syncReadingPositionAlertBody,
                                    preferredStyle: .alert)

      let stayText = DisplayStrings.stay
      let stayAction = UIAlertAction(title: stayText, style: .cancel) { _ in
        continuation.resume()
      }

      let moveText = DisplayStrings.move
      let moveAction = UIAlertAction(title: moveText, style: .default) { _ in
        let loc = TPPBookLocation(locator: serverLocator,
                                  type: "LocatorHrefProgression",
                                  publication: publication)
        self.bookRegistry.setLocation(loc, forIdentifier: book.identifier)
        continuation.resume()
      }

      alert.addAction(stayAction)
      alert.addAction(moveAction)

      TPPPresentationUtils.safelyPresent(alert)
    }
  }
}
