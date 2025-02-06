//
//  TPPLastReadPositionPoster.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared

/// A front-end to the Annotations API to post a new reading progress for a given book.
class TPPLastReadPositionPoster {
  /// Interval used to throttle request submission.
  static let throttlingInterval: TimeInterval = 15.0

  // Models
  private let publication: Publication
  private let book: TPPBook

  // External dependencies
  private let bookRegistryProvider: TPPBookRegistryProvider

  // Internal state management
  private var lastReadPositionUploadDate: Date
  private var queuedReadPosition: Locator?
  private let serialQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).lastReadPositionPoster", qos: .utility)

  init(book: TPPBook,
       publication: Publication,
       bookRegistryProvider: TPPBookRegistryProvider) {
    self.book = book
    self.publication = publication
    self.bookRegistryProvider = bookRegistryProvider
    self.lastReadPositionUploadDate = Date()
      .addingTimeInterval(-TPPLastReadPositionPoster.throttlingInterval)

    NotificationCenter.default.addObserver(self,
                                           selector: #selector(postQueuedReadPositionInSerialQueue),
                                           name: UIApplication.willResignActiveNotification,
                                           object: nil)
  }

  // MARK: - Storing

  /// Stores a new reading progress location on the server.
  /// - Parameter locator: The new local progress to be stored.
  func storeReadPosition(locator: Locator) {
    guard shouldStore(locator: locator) else { return }

    // Save location locally
    let location = TPPBookLocation(locator: locator, type: "LocatorHrefProgression", publication: publication)
    bookRegistryProvider.setLocation(location, forIdentifier: book.identifier)

    // Queue posting of this position
    postReadPosition(locator: locator)
  }

  /// Determines if a locator should be stored and posted.
  private func shouldStore(locator: Locator) -> Bool {
    let progression = locator.locations.totalProgression ?? 0
    return progression > 0 || locator.locations.otherLocations["cssSelector"] != nil
  }

  /// Queues the read position for posting.
  ///
  /// Requests are throttled to avoid excessive updates.
  private func postReadPosition(locator: Locator) {
    serialQueue.async { [weak self] in
      guard let self = self else { return }

      self.queuedReadPosition = locator

      if Date() > self.lastReadPositionUploadDate.addingTimeInterval(TPPLastReadPositionPoster.throttlingInterval) {
        self.postQueuedReadPosition()
      }
    }
  }

  private func postQueuedReadPosition() {
    guard let locator = self.queuedReadPosition, let selectorValue = locator.jsonString else { return }

    TPPAnnotations.postReadingPosition(forBook: book.identifier,
                                       selectorValue: selectorValue,
                                       motivation: .readingProgress)

    self.queuedReadPosition = nil
    self.lastReadPositionUploadDate = Date()
  }

  @objc private func postQueuedReadPositionInSerialQueue() {
    serialQueue.async { [weak self] in
      self?.postQueuedReadPosition()
    }
  }
}
