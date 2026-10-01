//
//  LCPPDFDiskExtract.swift
//  Palace
//
//  Disk-extract pipeline for LCP-protected PDFs. Streaming the encrypted
//  publication into Readium's PDF navigator does random-access reads that
//  defeat the decrypt cache and OOM on large PDFs, so we decrypt in one linear
//  pass to a temp .pdf and hand it to PDFKit, which mmaps it.
//
//  Cache: <accountDir>/registry/lcp-pdf-extracts/<bookIdentifierSHA256>.pdf.
//  The LCP container is immutable for the loan, and `invalidate` runs on
//  return. The extract sits in the app's private container under iOS data
//  protection.
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
    /// as a PDF; a partial file from an aborted extract is deleted so the next
    /// `extract` rebuilds it.
    ///
    /// Validation is a `%PDF-` magic-byte and minimum-size check rather than
    /// `PDFDocument(url:)`, which would parse the whole xref table of a large
    /// extract.
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
    /// Explicit `read(range:)` chunks rather than `stream(consume:)`, which
    /// stalled on device with LCP resources; fixed chunks also give a steady
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
