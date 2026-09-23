//
//  TPPPDFDocumentMetadata.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import PalaceLogging
import PalaceReadingPosition
import PalaceBookModel
import PalaceBookRegistry

/// PDF Document metadata
///
/// This object handles interaction between Objective-C code, TPPBookRegistry for storing PDF book current page and bookmarks, and SwiftUI code.
///
/// - Note: `@unchecked Sendable` is safe here: this is a SwiftUI `ObservableObject`
///   whose mutable `@Published` state is only ever mutated on the main thread
///   (the Combine `RunLoop.main` sink and explicit `DispatchQueue.main` hops).
///   The injected dependencies (`book`, `bookRegistry`, `positionWriter`,
///   `deviceID`) are immutable `let`s. Background `Task`s touch `self` only after
///   hopping to main, so capturing `self` in those main-thread `@Sendable`
///   closures crosses no Sendable boundary.
@objc class TPPPDFDocumentMetadata: NSObject, ObservableObject, @unchecked Sendable {
    private let rendererString = "TPPPDFReader"
    let book: TPPBook
    private let bookRegistry: TPPBookRegistryProvider
    private let positionWriter: PositionWriter
    private let deviceID: String
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
            (pdfBookmarks ?? []).map { $0.page }
        )
    }

    /// Bookmark page numbers of bookmarks stored in the book registry
    private var localBookmarks: Set<Int> {
        Set(
            bookRegistry.genericBookmarksForIdentifier(book.identifier)
                .compactMap { $0.pageNumber }
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
    init(with book: TPPBook,
         bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
         positionWriter: PositionWriter? = nil) {
        self.book = book
        self.bookRegistry = bookRegistry
        self.positionWriter = positionWriter ?? EPUBPositionWriterFactory.make(for: book)
        self.deviceID = AnnotationDevice.currentID()
        currentPage = bookRegistry.location(forIdentifier: book.identifier)?.pageNumber ?? 0
        bookRegistry.setState(.used, for: book.identifier)
        super.init()
        bookmarks = localBookmarks
        fetchReadingPosition()
        fetchBookmarks()
        currentPageCancellable = $currentPage
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.setCurrentPage(value)
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
        bookRegistry.setLocation(location, forIdentifier: self.bookIdentifier)
        if canSync {
            let snapshot = PositionSnapshot(
                bookID: bookIdentifier,
                format: .pdfPage,
                payload: Data(bookmarkSelector.utf8),
                timestamp: Date(),
                device: deviceID
            )
            Task { [positionWriter] in
                _ = try? await positionWriter.save(snapshot)
            }
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
                // Hoist the `Int` page out of the non-Sendable `TPPPDFPageBookmark`
                // before the main-thread hop so the `@Sendable` closure captures
                // only `Sendable` values (`page` + the now-`Sendable` `self`).
                let page = pdfBookmark.page
                DispatchQueue.main.async { [weak self] in
                    self?.remotePage = page
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
        // Clear any prior Stay decision so the next genuinely-new
        // remote page surfaces a prompt again.
        Self.clearDeclinedRemotePage(forBookIdentifier: bookIdentifier)
    }

    /// Records that the user chose Stay for the current remote page,
    /// so subsequent opens with the SAME remote page won't re-prompt.
    /// If the server later advances to a different page (i.e., real
    /// new progress from another device), the prompt fires again.
    func dismissRemotePageSync() {
        guard let remotePage = remotePage else { return }
        Self.storeDeclinedRemotePage(remotePage, forBookIdentifier: bookIdentifier)
    }

    /// Whether the sync-position prompt should fire for the current
    /// `(currentPage, remotePage)` combination. Suppresses prompts
    /// when the values match, when there's no remote position, or
    /// when the user has previously chosen Stay for this remote-page
    /// value on this book.
    func shouldPromptRemotePageSync() -> Bool {
        guard let remotePage = remotePage else { return false }
        if remotePage == currentPage { return false }
        if Self.declinedRemotePage(forBookIdentifier: bookIdentifier) == remotePage { return false }
        return true
    }

    // MARK: - Decline persistence
    //
    // Stored in UserDefaults keyed by book identifier. The value is the
    // remote-page number the user explicitly chose NOT to sync to. We
    // only suppress the prompt if the CURRENT remote page matches —
    // if the server later moves to a different page (e.g., the user
    // read further on another device), the new value surfaces the
    // prompt again.

    private static let declinedRemotePagePrefix = "TPPPDFDocumentMetadata.declinedRemotePage."

    private static func storeDeclinedRemotePage(_ page: Int, forBookIdentifier identifier: String) {
        UserDefaults.standard.set(page, forKey: declinedRemotePagePrefix + identifier)
    }

    private static func declinedRemotePage(forBookIdentifier identifier: String) -> Int? {
        let key = declinedRemotePagePrefix + identifier
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    private static func clearDeclinedRemotePage(forBookIdentifier identifier: String) {
        UserDefaults.standard.removeObject(forKey: declinedRemotePagePrefix + identifier)
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
        if let locationString = page.locationString, let location = TPPBookLocation(locationString: locationString, renderer: rendererString) {
            bookRegistry.addGenericBookmark(location, forIdentifier: bookIdentifier)
        }
        if canSync {
            TPPAnnotations.postBookmark(page, annotationsURL: book.annotationsURL ?? TPPAnnotations.annotationsURL, forBookID: bookIdentifier) { response in
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
        bookRegistry.genericBookmarksForIdentifier(bookIdentifier)
            .filter { $0.pageNumber == page.pageNumber }
            .forEach { location in
                bookRegistry.deleteGenericBookmark(location, forIdentifier: bookIdentifier)
            }
        if canSync,
           let bookmark = pdfBookmarks?.first(where: { page.pageNumber == $0.page }),
           let annotationId = bookmark.annotationID {
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
