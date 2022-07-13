//
//  TPPPDFDocumentMetadata.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// PDF Document metadata
///
/// This object handles interaction between Objective-C code, TPPBookRegistry for storing PDF book current page and bookmarks, and SwiftUI code.
@objc class TPPPDFDocumentMetadata: NSObject, ObservableObject {
  private let rendererString = "TPPPDFReader"
  let bookIdentifier: String
  
  /// Provides book title available in `TPPBook` object.
  @objc var title: String?
  
  /// Page numbers for boomarks.
  @Published var bookmarks: [Int]?
  
  /// Current page number.
  @Published var currentPage: Int {
    didSet {
      setCurrentPage(currentPage)
    }
  }
  
  /// Initializes metadata.
  /// - Parameter bookIdentifier: PDF book identifier string.
  ///
  /// This function gets data from `TPPBookRegistry`,
  /// `bookIdentifier` must be present in the registry, otherwise the app crashes..
  @objc init(with bookIdentifier: String) {
    self.bookIdentifier = bookIdentifier
    currentPage = TPPBookRegistry.shared().location(forIdentifier: bookIdentifier)?.pageNumber ?? 0
    bookmarks = TPPBookRegistry.shared().genericBookmarks(forIdentifier: bookIdentifier)?.compactMap { $0.pageNumber }
    TPPBookRegistry.shared().setStateWithCode(TPPBookState.Used.rawValue, forIdentifier: bookIdentifier)
  }
  
  /// Set current page in the book registry.
  /// - Parameter page: PDF page number.
  ///
  /// This function preserves last opened page in the book registry.
  func setCurrentPage(_ page: Int) {
    guard let locationString = TPPPDFPage(pageNumber: page).locationString,
          let location = TPPBookLocation(locationString: locationString, renderer: rendererString)
    else {
      Log.error(#file, "Error creating and saving PDF Page Location")
      return
    }
    TPPBookRegistry.shared().setLocation(location, forIdentifier: self.bookIdentifier)
  }
  
  /// Add bookmark for the book to the book registry.
  /// - Parameter page: PDF page number, `nil` adds current page.
  func addBookmark(at page: Int? = nil) {
    guard let locationString = TPPPDFPage(pageNumber: page ?? currentPage).locationString,
          let location = TPPBookLocation(locationString: locationString, renderer: rendererString)
    else {
      Log.error(#file, "Error adding PDF Page Location")
      return
    }
    TPPBookRegistry.shared().addGenericBookmark(location, forIdentifier: bookIdentifier)
    bookmarks = TPPBookRegistry.shared().genericBookmarks(forIdentifier: bookIdentifier)?.compactMap { $0.pageNumber }
  }
  
  /// Remove bookmark from the book registry.
  /// - Parameter page: PDF page number, `nil` removes current page.
  func removeBookmark(at page: Int? = nil) {
    guard let locationString = TPPPDFPage(pageNumber: page ?? currentPage).locationString,
          let location = TPPBookLocation(locationString: locationString, renderer: rendererString)
    else {
      Log.error(#file, "Error adding PDF Page Location")
      return
    }
    TPPBookRegistry.shared().deleteGenericBookmark(location, forIdentifier: bookIdentifier)
    bookmarks = TPPBookRegistry.shared().genericBookmarks(forIdentifier: bookIdentifier)?.compactMap { $0.pageNumber }
  }
  
  /// Checks if page is bookmarked.
  /// - Parameter page: PDF page number, `nil` check if current page is in bookmarks.
  /// - Returns: `true` of the page is bookmarked, `false` otherwise.
  func isBookmarked(page: Int? = nil) -> Bool {
    bookmarks?.contains(page ?? currentPage) ?? false
  }
}