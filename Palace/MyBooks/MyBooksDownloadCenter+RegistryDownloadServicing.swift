//
//  MyBooksDownloadCenter+RegistryDownloadServicing.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// `MyBooksDownloadCenter`'s conformance to the registry's download seam
/// (god-class decomposition Wave 2b). `fileUrl(for:account:)`,
/// `deleteLocalContent(forBook:account:)`, and `redownloadLCPContentFile(for:)`
/// are satisfied by the download center's existing methods; the two additions
/// below own the `#if LCP` license-vs-content probe that USED to live inside
/// `BookRegistrySync.checkIfBookFileExists` — the SPM package never sees the app's
/// `LCP` compilation condition, so that logic MUST live here. Palace-noDRM builds
/// this file with `LCP` undefined, giving the plain non-LCP behavior (content-file
/// existence / `false`), mirroring the pre-extraction `#else` branches exactly.
extension MyBooksDownloadCenter: RegistryDownloadServicing {

    /// Protocol witness for the no-request start (the download center's own
    /// `startDownload(for:withRequest:)` has a defaulted param, which cannot serve
    /// as a witness for the parameter-less requirement).
    public func startDownload(for book: TPPBook) {
        startDownload(for: book, withRequest: nil)
    }

    /// Whether the book's content is satisfied on disk. For an LCP audiobook the
    /// `.lcpl` license alone counts as satisfied (playable via streaming) even when
    /// the `.lcpa` content file is absent; every other book requires the content
    /// file itself. Byte-for-byte the former `checkIfBookFileExists` body.
    public func contentFileSatisfied(for book: TPPBook, account: String) -> Bool {
        guard let bookURL = fileUrl(for: book, account: account) else {
            return false
        }

        let fileExists = FileManager.default.fileExists(atPath: bookURL.path)

        #if LCP
        if LCPAudiobooks.canOpenBook(book) {
            let licenseURL = bookURL.deletingPathExtension().appendingPathExtension("lcpl")
            let licenseExists = FileManager.default.fileExists(atPath: licenseURL.path)

            if licenseExists {
                return true
            }

            return fileExists
        }
        #endif

        return fileExists
    }

    /// Whether an LCP audiobook is playable-via-streaming (license present, counted
    /// satisfied above) but missing its local `.lcpa` content file — the signal to
    /// schedule a silent background re-download (PP-3704). noDRM: always `false`.
    public func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool {
        #if LCP
        if LCPAudiobooks.canOpenBook(book),
           let bookURL = fileUrl(for: book, account: account),
           !FileManager.default.fileExists(atPath: bookURL.path) {
            return true
        }
        #endif
        return false
    }
}
