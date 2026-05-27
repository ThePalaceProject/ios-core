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

    /// Returns the cached extracted-PDF URL if a usable extract exists
    /// for this book. "Usable" means present on disk **and** parseable
    /// as a PDF — a partial file from a prior crashed/aborted extract
    /// (e.g. the device OOMed mid-write before we added chunked reads)
    /// would still pass a `fileExists` check but explode at PDFKit
    /// open time as "Unable to load PDF file." If the cached file is
    /// malformed we delete it here so the next `extract` call rebuilds
    /// it cleanly.
    ///
    /// Validation is `%PDF-` magic byte check + minimum-size sanity
    /// (a 4-byte file is not a PDF). We DON'T spin up a full
    /// `PDFDocument(url:)` to validate because that mmaps + parses the
    /// whole xref table on big files (~830MB extracts), which is
    /// exactly the work we want to defer to the actual reader.
    static func cachedURL(bookIdentifier: String, account: String) -> URL? {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return nil }
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? Int) ?? 0
            if size < 1024 {
                Log.warn(#file, "[PERF] [LCP-PDF] cached extract too small (\(size) bytes) — treating as corrupt, deleting")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            // %PDF- = 0x25 0x50 0x44 0x46 0x2D
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 5)) ?? Data()
            if header != Data([0x25, 0x50, 0x44, 0x46, 0x2D]) {
                let preview = header.map { String(format: "%02x", $0) }.joined()
                Log.warn(#file, "[PERF] [LCP-PDF] cached extract is not a PDF (header=\(preview)) — deleting and re-extracting")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url
        } catch {
            Log.warn(#file, "[PERF] [LCP-PDF] cached extract validation failed: \(error.localizedDescription) — deleting")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Reads the publication's PDF resource in fixed-size chunks via
    /// `Resource.read(range:)`, writing each chunk to a temp file.
    /// Returns the final file URL on success.
    ///
    /// **Why explicit chunked reads instead of `stream(consume:)`:**
    /// the LCP-wrapped Resource's `stream(consume:)` was hanging at
    /// ~1% on device in the first attempt — either it was emitting
    /// one giant chunk (forcing a full-file allocation in Readium's
    /// internals before our consume fired), or the chunking was
    /// unpredictable for our progress UI. With explicit `read(range:)`
    /// calls we pin the chunk size, give the OS time to flush the
    /// FileHandle between chunks, and produce a steady per-chunk
    /// progress signal.
    static func extract(
        publication: Publication,
        bookIdentifier: String,
        account: String
    ) async throws -> URL {
        guard let destURL = fileURL(bookIdentifier: bookIdentifier, account: account) else {
            throw ExtractError.missingAccountDir
        }
        guard let link = publication.readingOrder.first else {
            Log.error(#file, "[PERF] [LCP-PDF] readingOrder is empty for \(bookIdentifier)")
            throw ExtractError.noReadingOrder
        }
        Log.info(#file, "[PERF] [LCP-PDF] extract link: href=\(String(describing: link.href)) type=\(String(describing: link.mediaType))")
        guard let resource = publication.get(link) else {
            Log.error(#file, "[PERF] [LCP-PDF] publication.get returned nil for \(bookIdentifier)")
            throw ExtractError.noResource
        }

        // Pre-create the destination directory.
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        parentDir.excludeFromBackup()

        // Probe the total size. `estimatedLength()` is a hint pulled
        // from the resource header (often the ZIP entry's uncompressed
        // size for LCP containers). If it's missing we still proceed
        // and just don't show a denominator-based %.
        let totalBytes: UInt64?
        switch await resource.estimatedLength() {
        case .success(let length): totalBytes = length
        case .failure(let error):
            Log.warn(#file, "[PERF] [LCP-PDF] estimatedLength failed: \(error.localizedDescription)")
            totalBytes = nil
        }
        await LCPPDFOpenProgress.shared.setTotalExtractBytes(totalBytes ?? 0)

        Log.info(#file, "[PERF] [LCP-PDF] disk-extract begin: \(bookIdentifier) total=\(totalBytes ?? 0) bytes → \(destURL.lastPathComponent)")
        let startedAt = Date()

        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw ExtractError.writeFailed("could not open FileHandle for \(destURL.path)")
        }
        defer { try? handle.close() }

        // 1MB chunks: enough to amortize the per-call decrypt overhead
        // but small enough that peak transient memory stays bounded.
        let chunkSize: UInt64 = 1024 * 1024
        var offset: UInt64 = 0

        // If we don't know the total length we can't loop on ranges —
        // fall back to the stream(consume:) path for that case.
        guard let total = totalBytes, total > 0 else {
            Log.warn(#file, "[PERF] [LCP-PDF] no totalBytes — falling back to stream(consume:)")
            let result = await resource.stream(range: nil) { chunk in
                do { try handle.write(contentsOf: chunk) }
                catch { Log.error(#file, "stream write failed: \(error.localizedDescription)") }
                LCPPDFOpenProgress.shared.recordExtractedBytes(chunk.count)
            }
            switch result {
            case .success:
                return destURL
            case .failure(let error):
                try? FileManager.default.removeItem(at: destURL)
                throw ExtractError.streamFailed(error.localizedDescription)
            }
        }

        while offset < total {
            let end = min(offset + chunkSize, total)
            let range = offset..<end
            switch await resource.read(range: range) {
            case .success(let chunk):
                do { try handle.write(contentsOf: chunk) }
                catch {
                    try? FileManager.default.removeItem(at: destURL)
                    throw ExtractError.writeFailed(error.localizedDescription)
                }
                LCPPDFOpenProgress.shared.recordExtractedBytes(chunk.count)
                offset = end
                // Cheap forward-progress log on the first chunk + every
                // 16 MB so a stall is visible without flooding.
                if offset == end && (offset == chunkSize || offset % (16 * 1024 * 1024) == 0) {
                    Log.info(#file, "[PERF] [LCP-PDF] extract progress: \(offset)/\(total) bytes (\(Int(Double(offset) * 100.0 / Double(total)))%) elapsed=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: destURL)
                Log.error(#file, "[PERF] [LCP-PDF] read(range: \(range)) failed: \(error.localizedDescription)")
                throw ExtractError.streamFailed(error.localizedDescription)
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let writtenBytes = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        Log.info(#file, "[PERF] [LCP-PDF] disk-extract done: \(bookIdentifier) wrote=\(writtenBytes) bytes in \(elapsedMs)ms")
        return destURL
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
