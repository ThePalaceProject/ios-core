//
//  LCPPDFDiskExtract.swift
//  Palace
//
//  Disk-extract pipeline for LCP-protected PDFs. The previous render
//  path streamed bytes directly from the LCP-encrypted publication into
//  Readium's `PDFNavigatorViewController` — but PDFNavigator does
//  random-access reads on the PDF cross-reference table, and AES-CBC
//  produces uniformly-unique ciphertext for each file offset, so the
//  in-process decrypt cache never hits. On a large Marketplace PDF
//  this produced 800,000+ decrypts before page 1 painted, with ~9 KB
//  retained per call — guaranteed OOM (see device log captured against
//  Power Rangers Unlimited: residentMB went from 1.8 GB to 2.8 GB in
//  10 seconds, then jetsam).
//
//  The fix: do ONE linear pass through the Readium `Resource` (which
//  streams decrypted bytes), write the output to a temp .pdf on disk,
//  then hand the temp file to PDFKit via the legacy `TPPPDFReaderView`.
//  PDFKit mmaps the on-disk file and pages in on demand — no LCP
//  decrypt loop, no retained per-read buffers.
//
//  Cache layout, per-account:
//
//      <accountDir>/registry/lcp-pdf-extracts/<bookIdentifierSHA256>.pdf
//
//  Cache invariant: the LCP container is immutable for the loan window,
//  so the same SHA256(identifier) is a stable filename. On return /
//  re-borrow the registry path changes (LocalBookContentService calls
//  `invalidate` here alongside the existing TOC cache invalidation),
//  so we don't have to hand-detect file changes. The extracted file
//  inherits no DRM — it sits in the app's private container, encrypted
//  by iOS data protection, and is removed on loan return.
//

#if LCP

import Foundation
import ReadiumShared
import PalaceLogging

enum LCPPDFDiskExtract {

    enum ExtractError: Error {
        case noReadingOrder
        case noResource
        case streamFailed(String)
        case writeFailed(String)
        case missingAccountDir
    }

    /// Returns the cached extracted-PDF URL if one exists for this book.
    static func cachedURL(bookIdentifier: String, account: String) -> URL? {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Streams the publication's PDF resource through Readium's decrypt
    /// pipeline, writing each chunk to a temp file. Returns the final
    /// file URL on success. Progress is reported on
    /// `LCPPDFOpenProgress.shared` so the loading view can display a
    /// byte-accurate percentage.
    ///
    /// The work is wholly async — chunks are written to a `FileHandle`
    /// so the in-memory footprint stays at one chunk (≪1 MB) for the
    /// duration of the stream. Compare to PDFNavigator's
    /// random-access path which buffered tens of MB of retained
    /// decrypt outputs.
    static func extract(
        publication: Publication,
        bookIdentifier: String,
        account: String
    ) async throws -> URL {
        guard let destURL = fileURL(bookIdentifier: bookIdentifier, account: account) else {
            throw ExtractError.missingAccountDir
        }
        guard let link = publication.readingOrder.first else {
            throw ExtractError.noReadingOrder
        }
        guard let resource = publication.get(link) else {
            throw ExtractError.noResource
        }

        // Pre-create the destination directory.
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        parentDir.excludeFromBackup()

        // Estimate total size up front so the progress bar has a real
        // denominator. `estimatedLength()` returns the Resource's
        // declared length (often pulled from the ZIP header) — a hint,
        // not a guarantee, but accurate enough for UI feedback.
        let totalBytes: UInt64?
        switch await resource.estimatedLength() {
        case .success(let length): totalBytes = length
        case .failure: totalBytes = nil
        }
        await LCPPDFOpenProgress.shared.setTotalExtractBytes(totalBytes ?? 0)

        Log.info(#file, "[PERF] [LCP-PDF] disk-extract begin: \(bookIdentifier) total=\(totalBytes ?? 0) bytes → \(destURL.lastPathComponent)")
        let startedAt = Date()

        // Write through a FileHandle so per-chunk writes don't reopen
        // the file each time. Truncate any partial file from a prior
        // aborted extraction.
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw ExtractError.writeFailed("could not open FileHandle for \(destURL.path)")
        }
        defer { try? handle.close() }

        // Stream loop. The `consume` callback is invoked by Readium
        // for each decrypted chunk. We block-write each chunk to disk
        // immediately so the in-memory footprint stays bounded.
        let result = await resource.stream(range: nil) { chunk in
            // Best-effort write; if this throws we still see it as the
            // stream's eventual failure result.
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                Log.error(#file, "disk-extract chunk write failed: \(error.localizedDescription)")
            }
            LCPPDFOpenProgress.shared.recordExtractedBytes(chunk.count)
        }

        switch result {
        case .success:
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let writtenBytes = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
            Log.info(#file, "[PERF] [LCP-PDF] disk-extract done: \(bookIdentifier) wrote=\(writtenBytes) bytes in \(elapsedMs)ms")
            return destURL
        case .failure(let error):
            // Best-effort cleanup of the partial file.
            try? FileManager.default.removeItem(at: destURL)
            throw ExtractError.streamFailed(error.localizedDescription)
        }
    }

    /// Drops the on-disk extracted PDF for one book. Call when the loan
    /// is returned so a re-borrow doesn't reuse a stale extract against
    /// potentially different content. Best-effort.
    static func invalidate(bookIdentifier: String, account: String) {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Path

    /// `<accountDir>/registry/lcp-pdf-extracts/<sha256(bookIdentifier)>.pdf`.
    private static func fileURL(bookIdentifier: String, account: String) -> URL? {
        guard let accountDir = TPPBookContentMetadataFilesHelper.directory(for: account) else { return nil }
        let hashed = bookIdentifier.sha256()
        return accountDir
            .appendingPathComponent("registry")
            .appendingPathComponent("lcp-pdf-extracts")
            .appendingPathComponent("\(hashed).pdf")
    }
}

#endif
