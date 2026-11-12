//
//  TPPBook+CatalogEntry.swift
//  PalaceBookModel
//
//  Maps a catalog feed entry to the book a lane or list row shows.
//

import PalaceCatalog

extension TPPBook {
    // PUBLIC_INTENT: called from the app target by catalog lanes and book detail related lanes.
    /// The book to show for `entry`, or nil when the entry must be left out of
    /// the lane because the app cannot open it.
    ///
    /// `registryMetadata` returns the registry's copy of a book the patron
    /// already has (nil otherwise), so a row reflects what is on the device. It
    /// is a closure because the registry package depends on this one.
    public static func catalogBook(from entry: TPPOPDSEntry,
                                   registryMetadata: (TPPBook) -> TPPBook?) -> TPPBook? {
        guard var book = TPPBook(entry: entry) else { return nil }
        if let updated = registryMetadata(book) { book = updated }
        // `.unsupported` also covers a book with no default acquisition.
        if book.defaultBookContentType == .unsupported { return nil }
        return book
    }
}
