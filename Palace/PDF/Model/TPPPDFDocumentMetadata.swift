//
//  TPPPDFDocumentMetadata.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// PDF Document metadata
///
/// This object handles interaction between Objective-C code, TPPBookRegistry for storing PDF book current page and bookmarks, and SwiftUI code.
@objc class TPPPDFDocumentMetadata: NSObject, ObservableObject {
  private let rendererString = "TPPPDFReader"
  let book: TPPBook
  var bookIdentifier: String { book.identifier }

  /// Page numbers for boomarks.
  @Published var bookmarks = Set<Int>()

  /// Current page number.
  @Published var currentPage: Int

  @Published var remotePage: Int?

  private var currentPageCancellable: AnyCancellable?

  private var pdfBookmarks: [TPPPDFPageBookmark]? {
    didSet {
      bookmarks = localBookmarks.union(remoteBookmarks)
    }
  }

  /// Bookmark page numbers on the remote server
  private var remoteBookmarks: Set<Int> {
    Set(
      (pdfBookmarks ?? []).map(\.page)
    )
  }

  /// Bookmark page numbers of bookmarks stored in the book registry
  private var localBookmarks: Set<Int> {
    Set(
      TPPBookRegistry.shared.genericBookmarksForIdentifier(book.identifier)
        .compactMap(\.pageNumber)
    )
  }

  /// Returns `true` if current account allows synchronisation
  private var canSync: Bool {
    TPPAnnotations.syncIsPossibleAndPermitted()
  }

  /// Initializes metadata.
  /// - Parameter bookIdentifier: PDF book identifier string.
  ///
  /// This function gets data from `TPPBookRegistry`,
  /// `bookIdentifier` must be present in the registry, otherwise the app crashes..
  @objc init(with book: TPPBook) {
    self.book = book
    currentPage = TPPBookRegistry.shared.location(forIdentifier: book.identifier)?.pageNumber ?? 0
    TPPBookRegistry.shared.setState(.used, for: book.identifier)
    super.init()
    bookmarks = localBookmarks
    fetchReadingPosition()
    fetchBookmarks()
    currentPageCancellable = $currentPage
      .debounce(for: .seconds(1), scheduler: RunLoop.main)
      .removeDuplicates()
      .sink { value in
        self.setCurrentPage(value)
      }
  }

  /// Set current page in the book registry.
  /// - Parameter pageNumber: PDF page number.
  ///
  /// This function preserves last opened page in the book registry.
  func setCurrentPage(_ pageNumber: Int) {
    let page = TPPPDFPage(pageNumber: pageNumber)
    guard let locationString = page.locationString,
          let bookmarkSelector = page.bookmarkSelector,
          let location = TPPBookLocation(locationString: locationString, renderer: rendererString)
    else {
      Log.error(#file, "Error creating and saving PDF Page Location")
      return
    }
    TPPBookRegistry.shared.setLocation(location, forIdentifier: bookIdentifier)
    if canSync {
      TPPAnnotations.postReadingPosition(
        forBook: bookIdentifier,
        selectorValue: bookmarkSelector,
        motivation: .readingProgress
      )
    }
  }

  /// Fetch reading position stored on the server.
  func fetchReadingPosition() {
    guard canSync, let url = TPPAnnotations.annotationsURL else {
      return
    }

    Task {
      let bookmark = await TPPAnnotations.syncReadingPosition(ofBook: book, toURL: url)
      if let pdfBookmark = bookmark as? TPPPDFPageBookmark {
        DispatchQueue.main.async { [weak self] in
          self?.remotePage = pdfBookmark.page
        }
      }
    }
  }

  /// Synchronize reading position with the fetched position from the server.
  func syncReadingPosition() {
    guard let remotePage = remotePage else {
      return
    }
    currentPage = remotePage
  }

  /// Fetch bookmarks from the server.
  func fetchBookmarks() {
    guard canSync, let url = book.annotationsURL ?? TPPAnnotations.annotationsURL else {
      return
    }
    TPPAnnotations.getServerBookmarks(forBook: book, atURL: url) { bookmarks in
      if let pdfBookmarks = bookmarks as? [TPPPDFPageBookmark] {
        DispatchQueue.main.async {
          self.pdfBookmarks = pdfBookmarks
        }
      }
    }
  }

  /// Add bookmark for the book to the book registry.
  /// - Parameter pageNumber: PDF page number, `nil` adds current page.
  func addBookmark(at pageNumber: Int? = nil) {
    let page = TPPPDFPage(pageNumber: pageNumber ?? currentPage)
    bookmarks.insert(page.pageNumber)
    if let locationString = page.locationString, let location = TPPBookLocation(
      locationString: locationString,
      renderer: rendererString
    ) {
      TPPBookRegistry.shared.addGenericBookmark(location, forIdentifier: bookIdentifier)
    }
    if canSync {
      TPPAnnotations.postBookmark(
        page,
        annotationsURL: book.annotationsURL ?? TPPAnnotations.annotationsURL,
        forBookID: bookIdentifier
      ) { response in
        DispatchQueue.main.async {
          self.pdfBookmarks?.append(TPPPDFPageBookmark(page: page.pageNumber, annotationID: response?.serverId))
        }
      }
    }
  }

  /// Remove bookmark from the book registry.
  /// - Parameter pageNumber: PDF page number, `nil` removes current page.
  func removeBookmark(at pageNumber: Int? = nil) {
    let page = TPPPDFPage(pageNumber: pageNumber ?? currentPage)
    bookmarks.remove(page.pageNumber)
    TPPBookRegistry.shared.genericBookmarksForIdentifier(bookIdentifier)
      .filter { $0.pageNumber == page.pageNumber }
      .forEach { location in
        TPPBookRegistry.shared.deleteGenericBookmark(location, forIdentifier: bookIdentifier)
      }
    if canSync,
       let bookmark = pdfBookmarks?.first(where: { page.pageNumber == $0.page }),
       let annotationId = bookmark.annotationID
    {
      // Remove on the server
      TPPAnnotations.deleteBookmark(annotationId: annotationId) { _ in
        DispatchQueue.main.async {
          self.pdfBookmarks?.removeAll(where: { page.pageNumber == $0.page })
        }
      }
    }
  }

  /// Checks if page is bookmarked.
  /// - Parameter page: PDF page number, `nil` check if current page is in bookmarks.
  /// - Returns: `true` of the page is bookmarked, `false` otherwise.
  func isBookmarked(page: Int? = nil) -> Bool {
    bookmarks.contains(page ?? currentPage)
  }
}
