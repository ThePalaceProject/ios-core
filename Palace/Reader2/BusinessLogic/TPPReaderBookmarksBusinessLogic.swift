//
//  TPPReaderBookmarksBusinessLogic.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 5/1/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import ReadiumShared
import ReadiumNavigator

/// Encapsulates all of the SimplyE business logic related to bookmarking
/// for a given book.
class TPPReaderBookmarksBusinessLogic: NSObject {

  var bookmarks: [TPPReadiumBookmark] = []
  let book: TPPBook
  private let publication: Publication
  private let drmDeviceID: String?
  private let bookRegistry: TPPBookRegistryProvider
  private let currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider
  private let bookmarksFactory: TPPBookmarkFactory

  init(book: TPPBook,
       r2Publication: Publication,
       drmDeviceID: String?,
       bookRegistryProvider: TPPBookRegistryProvider,
       currentLibraryAccountProvider: TPPCurrentLibraryAccountProvider) {
    self.book = book
    self.publication = r2Publication
    self.drmDeviceID = drmDeviceID
    self.bookRegistry = bookRegistryProvider
    bookmarks = bookRegistryProvider.readiumBookmarks(forIdentifier: book.identifier)
    self.currentLibraryAccountProvider = currentLibraryAccountProvider
    self.bookmarksFactory = TPPBookmarkFactory(book: book,
                                                publication: publication,
                                                drmDeviceID: drmDeviceID)

    super.init()
  }

  func bookmark(at index: Int) -> TPPReadiumBookmark? {
    guard index >= 0 && index < bookmarks.count else {
      return nil
    }

    return bookmarks[index]
  }

  /// Derives Readium 2 location information for bookmarking from current
  /// navigation state.
  ///
  /// - Parameter navigator: The `Navigator` object used to browse
  /// the `publication`.
  /// - Returns: Location information related to the current reading position.
  func currentLocation(in navigator: Navigator) -> TPPBookmarkR3Location? {
    guard
      let locator = navigator.currentLocation,
      let index = publication.resourceIndex(forLocator: locator) else {
        return nil
    }

    return TPPBookmarkR3Location(resourceIndex: index, locator: locator)
  }

  /// Verifies if a bookmark exists at the given location.
  /// - Parameter location: The Readium 2 location to be checked.
  /// - Returns: The bookmark at the given `location` if it exists,
  /// otherwise nil.
  func isBookmarkExisting(at location: TPPBookmarkR3Location?) -> TPPReadiumBookmark? {
    guard let currentLocator = location?.locator else {
      return nil
    }

    return bookmarks.first(where: { $0.locationMatches(currentLocator)})
  }

  /// Creates a new bookmark at the given location for the publication.
  ///
  /// The bookmark is added to the internal list of bookmarks, and the list
  /// is kept sorted by progression-within-book, in ascending order.
  ///
  /// - Parameter bookmarkLoc: The location to boomark.
  ///
  /// - Returns: A newly created bookmark object, unless the input location
  /// lacked progress information.
  func addBookmark(_ bookmarkLoc: TPPBookmarkR3Location) async -> TPPReadiumBookmark? {
    guard let bookmark =
            await bookmarksFactory.make(
              fromR3Location: bookmarkLoc,
              usingBookRegistry: bookRegistry,
              for: self.book,
              publication: publication
            ) else {
      return nil
    }

    bookmarks.append(bookmark)
    bookmarks.sort { $0.progressWithinBook < $1.progressWithinBook }

    postBookmark(bookmark)

    return bookmark
  }
    
  private func postBookmark(_ bookmark: TPPReadiumBookmark) {
    guard
      let currentAccount = currentLibraryAccountProvider.currentAccount,
      let accountDetails = currentAccount.details,
      accountDetails.syncPermissionGranted else {
        self.bookRegistry.add(bookmark, forIdentifier: book.identifier)
        return
    }
    
    TPPAnnotations.postBookmark(bookmark, forBookID: book.identifier) { response in
      Log.debug(#function, response?.serverId != nil ? "Bookmark upload succeed" : "Bookmark failed to upload")
      bookmark.annotationId = response?.serverId
      self.bookRegistry.add(bookmark, forIdentifier: self.book.identifier)
    }
  }

  func deleteBookmark(_ bookmark: TPPReadiumBookmark) {
    var wasDeleted = false
    bookmarks.removeAll  {
      let isMatching = $0.isEqual(bookmark)
      if isMatching {
        wasDeleted = true
      }
      return isMatching
    }

    if wasDeleted {
      didDeleteBookmark(bookmark)
    }
  }

  func deleteBookmark(at index: Int) -> TPPReadiumBookmark? {
    guard index >= 0 && index < bookmarks.count else {
      return nil
    }

    let bookmark = bookmarks.remove(at: index)
    didDeleteBookmark(bookmark)

    return bookmark
  }

  private func didDeleteBookmark(_ bookmark: TPPReadiumBookmark) {
    bookRegistry.delete(bookmark, forIdentifier: book.identifier)

    guard let currentAccount = currentLibraryAccountProvider.currentAccount,
        let details = currentAccount.details,
        let annotationId = bookmark.annotationId else {
      Log.debug(#file, "Delete on Server skipped: Annotation ID did not exist for bookmark.")
      return
    }
    
    if details.syncPermissionGranted && annotationId.count > 0 {
      TPPAnnotations.deleteBookmark(annotationId: annotationId) { (success) in
        Log.debug(#file, success ?
          "Bookmark successfully deleted" :
          "Failed to delete bookmark from server. Will attempt again on next Sync")
      }
    }
  }

  var noBookmarksText: String {
    Strings.TPPReaderBookmarksBusinessLogic.noBookmarks
  }

  func shouldSelectBookmark(at index: Int) -> Bool {
    return true
  }

  // MARK: - Bookmark Syncing

  func shouldAllowRefresh() -> Bool {
    return TPPAnnotations.syncIsPossibleAndPermitted()
  }
    
  func syncBookmarks(completion: @escaping (Bool, [TPPReadiumBookmark]) -> ()) {
      guard Reachability.shared.isConnectedToNetwork() else {
        self.handleBookmarksSyncFail(message: "Error: host was not reachable for bookmark sync attempt.",
                                     completion: completion)
        return
      }
                    
      Log.debug(#file, "Syncing bookmarks...")
      // First check for and upload any local bookmarks that have never been saved to the server.
      // Wait til that's finished, then download the server's bookmark list and filter out any that can be deleted.
      let localBookmarks = self.bookRegistry.readiumBookmarks(forIdentifier: self.book.identifier)
    TPPAnnotations.uploadLocalBookmarks(localBookmarks, forBook: self.book.identifier) { (bookmarksUploaded, bookmarksFailedToUpload) in
      for localBookmark in localBookmarks {
        for uploadedBookmark in bookmarksUploaded {
          if localBookmark.isEqual(uploadedBookmark) {
            self.bookRegistry.replace(localBookmark, with: uploadedBookmark, forIdentifier: self.book.identifier)
          }
        }
      }
      
      TPPAnnotations.getServerBookmarks(forBook: self.book, atURL: self.book.annotationsURL, motivation: .bookmark) { serverBookmarks in
        
        guard let serverBookmarks = serverBookmarks as? [TPPReadiumBookmark] else {
          self.handleBookmarksSyncFail(message: "Ending sync without running completion. Returning original list of bookmarks.",
                                       completion: completion)
          return
        }
        
        Log.debug(#file, serverBookmarks.count == 0 ? "No server bookmarks" : "Server bookmarks count: \(serverBookmarks.count)")
        
        self.updateLocalBookmarks(serverBookmarks: serverBookmarks,
                                  localBookmarks: localBookmarks,
                                  bookmarksFailedToUpload: bookmarksFailedToUpload)
        { [weak self] in
          guard let self = self else {
            completion(false, localBookmarks)
            return
          }
          self.bookmarks = self.bookRegistry.readiumBookmarks(forIdentifier: self.book.identifier)
          completion(true, self.bookmarks)
        }
      }
    }
  }
    
  func updateLocalBookmarks(serverBookmarks: [TPPReadiumBookmark],
                            localBookmarks: [TPPReadiumBookmark],
                            bookmarksFailedToUpload: [TPPReadiumBookmark],
                            completion: @escaping () -> ())
  {
    var localBookmarksToKeep = [TPPReadiumBookmark]()
    var serverBookmarksToAdd = [TPPReadiumBookmark]() + bookmarksFailedToUpload
    var serverBookmarksToDelete = [TPPReadiumBookmark]()

    for serverBookmark in serverBookmarks {
      if let localBookmark = localBookmarks.first(where: { $0.annotationId == serverBookmark.annotationId }) {
        localBookmarksToKeep.append(localBookmark)
      } else {
          serverBookmarksToAdd.append(serverBookmark)
      }
    }

    // Handle local deletions: only delete server bookmarks if they were created on this device and no longer exist locally
    for serverBookmark in serverBookmarks {
      if let deviceID = serverBookmark.device, let drmDeviceID = drmDeviceID, deviceID == drmDeviceID {
        if !localBookmarks.contains(where: { $0.annotationId == serverBookmark.annotationId }) {
          serverBookmarksToDelete.append(serverBookmark)
        }
      }
    }

    // Add missing bookmarks from server
    for bookmark in serverBookmarksToAdd {
      bookRegistry.add(bookmark, forIdentifier: self.book.identifier)
    }

    // Remove locally deleted bookmarks from the server
    TPPAnnotations.deleteBookmarks(serverBookmarksToDelete)

    completion()
  }

  private func handleBookmarksSyncFail(message: String,
                                       completion: @escaping (Bool, [TPPReadiumBookmark]) -> ()) {
    Log.info(#file, message)
    
    self.bookmarks = self.bookRegistry.readiumBookmarks(forIdentifier: self.book.identifier)
    completion(false, self.bookmarks)
  }
}
