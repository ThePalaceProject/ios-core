//
//  TPPLastReadPositionPoster.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import R2Shared

/// A front-end to the Annotations api to post a new reading progress for
/// a given book.
class TPPLastReadPositionPoster {
  /// Interval used to throttle request submission.
  static let throttlingInterval = 15.0

  // models
  private let publication: Publication
  private let book: TPPBook

  // external dependencies
  private let bookRegistryProvider: TPPBookRegistryProvider

  // internal state management
  private var lastReadPositionUploadDate: Date
  private var queuedReadPosition: String = ""
  private let serialQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).lastReadPositionPoster", target: .global(qos: .utility))

  init(book: TPPBook,
       r2Publication: Publication,
       bookRegistryProvider: TPPBookRegistryProvider) {
    self.book = book
    self.publication = r2Publication
    self.bookRegistryProvider = bookRegistryProvider
    self.lastReadPositionUploadDate = Date()
      .addingTimeInterval(-TPPLastReadPositionPoster.throttlingInterval)

    NotificationCenter.default.addObserver(self,
                                           selector: #selector(postQueuedReadPositionInSerialQueue),
                                           name: UIApplication.willResignActiveNotification,
                                           object: nil)
  }

  // MARK:- Storing

  /// Stores a new reading progress location on the server.
  /// - Parameter locator: The new local progress to be stored.
  func storeReadPosition(locator: Locator) {
    // Avoid overwriting location when reader first open
    guard (locator.locations.totalProgression ?? 0) != 0 || locator.locations.otherLocations["cssSelector"] != nil else {
      return
    }

    guard let location = TPPBookLocation(locator: locator, type: "LocatorHrefProgression", publication: publication) else {
      return
    }

    bookRegistryProvider.setLocation(location, forIdentifier: book.identifier)
    postReadPosition(selectorValue: location.locationString)
  }

  /// Deprecated
  ///
  /// Post the read position to server.
  ///
  /// Requests are throttled by a `throttlingInterval` to avoid an unreasonably
  /// high frequency of updates.
  ///
  /// - Parameter selectorValue: A JSON string that includes a serialized
  /// [locator](https://git.io/JYTyx) that uniquely identifies a position
  /// within the book.
  private func postReadPosition(selectorValue: String) {
    serialQueue.async { [weak self] in
      guard let self = self else { return }

      // save location string anyway so that if the app becomes inactive
      // we still have a chance to post it.
      self.queuedReadPosition = selectorValue

      if Date() > self.lastReadPositionUploadDate.addingTimeInterval(TPPLastReadPositionPoster.throttlingInterval) {
        self.postQueuedReadPosition()
      }
    }
  }

  private func postQueuedReadPosition() {
    if self.queuedReadPosition != "" {
      TPPAnnotations.postReadingPosition(forBook: book.identifier,
                                          selectorValue: self.queuedReadPosition,
                                          motivation: .readingProgress)
      self.queuedReadPosition = ""
      self.lastReadPositionUploadDate = Date()
    }
  }

  @objc private func postQueuedReadPositionInSerialQueue() {
    serialQueue.async { [weak self] in
      self?.postQueuedReadPosition()
    }
  }
}
