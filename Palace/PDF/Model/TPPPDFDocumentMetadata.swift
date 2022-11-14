//
//  TPPPDFDocumentMetadata.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// PDF Document metadata
///
/// This object handles interaction between Objective-C code, TPPBookRegistry for storing PDF book current page and bookmarks, and SwiftUI code.
@objc class TPPPDFDocumentMetadata: NSObject, ObservableObject {
  private let rendererString = "TPPPDFReader"
  let bookIdentifier: String
  
  /// Provides book title available in `TPPBook` object.
  @objc var title: String?
  
  /// Page numbers for boomarks.
  @Published var bookmarks: Set<Int>?
  
  /// Current page number.
  @Published var currentPage: Int
  
  private var currentPageCancellable: AnyCancellable?
  
  private var pdfBookmarks: [TPPPDFPageBookmark]? {
    didSet {
      bookmarks = (pdfBookmarks == nil ? nil : Set(pdfBookmarks!.map { $0.page }))
    }
  }
  
  /// Initializes metadata.
  /// - Parameter bookIdentifier: PDF book identifier string.
  ///
  /// This function gets data from `TPPBookRegistry`,
  /// `bookIdentifier` must be present in the registry, otherwise the app crashes..
  @objc init(with bookIdentifier: String) {
    self.bookIdentifier = bookIdentifier
    currentPage = TPPBookRegistry.shared.location(forIdentifier: bookIdentifier)?.pageNumber ?? 0
    TPPBookRegistry.shared.setState(.Used, for: bookIdentifier)
    super.init()
    syncReadingPosition()
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
    TPPBookRegistry.shared.setLocation(location, forIdentifier: self.bookIdentifier)
    TPPAnnotations.postReadingPosition(forBook: bookIdentifier, selectorValue: bookmarkSelector, motivation: .readingProgress)
  }
  
  /// Synchronize reading position with the position stored on the server.
  func syncReadingPosition() {
    guard let url = TPPAnnotations.annotationsURL else {
      return
    }
    TPPAnnotations.syncReadingPosition(ofBook: bookIdentifier, toURL: url) { [weak self] bookmark in
      if let pdfBookmark = bookmark as? TPPPDFPageBookmark {
        DispatchQueue.main.async {
          self?.currentPage = pdfBookmark.page
        }
      }
    }
  }
  
  /// Fetch bookmarks from the server.
  func fetchBookmarks() {
    guard let url = TPPAnnotations.annotationsURL else {
      return
    }
    TPPAnnotations.getServerBookmarks(forBook: bookIdentifier, atURL: url) { bookmarks in
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
    bookmarks?.insert(page.pageNumber)
    TPPAnnotations.postBookmark(page, forBookID: bookIdentifier) { serverID in
      DispatchQueue.main.async {
        self.pdfBookmarks?.append(TPPPDFPageBookmark(page: page.pageNumber, annotationID: serverID))
      }
    }
  }
  
  /// Remove bookmark from the book registry.
  /// - Parameter pageNumber: PDF page number, `nil` removes current page.
  func removeBookmark(at pageNumber: Int? = nil) {
    let bookmarkPage = pageNumber ?? currentPage
    guard let bookmark = pdfBookmarks?.first(where: { bookmarkPage == $0.page }),
          let annotationId = bookmark.annotationID
    else {
      Log.error(#file, "Error removing PDF Page Location")
      return
    }
    bookmarks?.remove(bookmarkPage)
    TPPAnnotations.deleteBookmark(annotationId: annotationId) { success in
      DispatchQueue.main.async {
        self.pdfBookmarks?.removeAll(where: { bookmarkPage == $0.page })
      }
    }
  }
  
  /// Checks if page is bookmarked.
  /// - Parameter page: PDF page number, `nil` check if current page is in bookmarks.
  /// - Returns: `true` of the page is bookmarked, `false` otherwise.
  func isBookmarked(page: Int? = nil) -> Bool {
    bookmarks?.contains(page ?? currentPage) ?? false
  }
}
