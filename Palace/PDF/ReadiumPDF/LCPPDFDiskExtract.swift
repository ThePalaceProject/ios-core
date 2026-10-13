//
//  LCPPDFDiskExtract.swift
//  Palace
//
//  Disk-extract pipeline for LCP-protected PDFs. Streaming the encrypted
//  publication into Readium's PDF navigator does random-access reads that
//  defeat the decrypt cache and OOM on large PDFs, so we decrypt in one linear
//  pass to a temp .pdf and hand it to PDFKit, which mmaps it.
//
//  Cache: <accountDir>/registry/lcp-pdf-extracts/<bookIdentifierSHA256>.pdf,
//  written as a `.partial` beside it and renamed into place when complete.
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
    /// as a PDF; a file that fails the check is deleted so the next `extract`
    /// rebuilds it. Extracts are renamed into place only once complete, so this
    /// catches files from builds that wrote the cache path directly.
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

        // If we don't know the total length we can't loop on ranges —
        // fall back to the stream(consume:) path for that case.
        guard let total = totalBytes, total > 0 else {
            Log.warn(#file, "[PERF] [LCP-PDF] no totalBytes — falling back to stream(consume:)")
            return try await writeFile(at: destURL) { handle in
                let result = await resource.stream(range: nil) { chunk in
                    guard !Task.isCancelled else { return }
                    do { try handle.write(contentsOf: chunk) }
                    catch { Log.error(#file, "stream write failed: \(error.localizedDescription)") }
                    LCPPDFOpenProgress.shared.recordExtractedBytes(chunk.count)
                }
                if case .failure(let error) = result {
                    throw ExtractError.streamFailed(error.localizedDescription)
                }
            }
        }

        return try await writeExtract(
            to: destURL,
            totalBytes: total,
            read: { range in await resource.read(range: range) },
            onChunk: { LCPPDFOpenProgress.shared.recordExtractedBytes($0) }
        )
    }

    /// Writes `totalBytes` read in `chunkSize` ranges to `destURL` and returns it.
    /// 1MB chunks amortize the per-call decrypt overhead while keeping peak
    /// transient memory bounded.
    static func writeExtract<Failure: Error>(
        to destURL: URL,
        totalBytes total: UInt64,
        chunkSize: UInt64 = 1024 * 1024,
        read: (Range<UInt64>) async -> Result<Data, Failure>,
        onChunk: (Int) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> URL {
        let startedAt = Date()
        let url = try await writeFile(at: destURL) { handle in
            var offset: UInt64 = 0
            while offset < total {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, total)
                let range = offset..<end
                switch await read(range) {
                case .success(let chunk):
                    // A back-out cancels the extract; stop before this chunk
                    // reaches the progress reporter the next open shares.
                    try Task.checkCancellation()
                    do { try handle.write(contentsOf: chunk) }
                    catch { throw ExtractError.writeFailed(error.localizedDescription) }
                    onChunk(chunk.count)
                    offset = end
                    // Forward-progress log on the first chunk and every 16 MB so
                    // a stall is visible without flooding.
                    if offset == chunkSize || offset % (16 * 1024 * 1024) == 0 {
                        Log.info(#file, "[PERF] [LCP-PDF] extract progress: \(offset)/\(total) bytes (\(Int(Double(offset) * 100.0 / Double(total)))%) elapsed=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                    }
                case .failure(let error):
                    Log.error(#file, "[PERF] [LCP-PDF] read(range: \(range)) failed: \(error.localizedDescription)")
                    throw ExtractError.streamFailed(error.localizedDescription)
                }
            }
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let writtenBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Log.info(#file, "[PERF] [LCP-PDF] disk-extract done: \(destURL.lastPathComponent) wrote=\(writtenBytes) bytes in \(elapsedMs)ms")
        return url
    }

    /// Runs `write` against a new `.partial` file beside `destURL` and renames it
    /// to `destURL` once `write` returns. `cachedURL` accepts any file at the
    /// cache path with a PDF header, so a reopen during an extract must never
    /// find a partly written one there; a unique name per extract also keeps a
    /// cancelled extract and its replacement from writing the same file. On a
    /// thrown error or cancellation the partial file is removed.
    private static func writeFile(at destURL: URL,
                                  isolation: isolated (any Actor)? = #isolation,
                                  _ write: (FileHandle) async throws -> Void) async throws -> URL {
        let partialURL = destURL.deletingLastPathComponent()
            .appendingPathComponent("\(partialPrefix(for: destURL))\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partialURL) else {
            throw ExtractError.writeFailed("could not open FileHandle for \(partialURL.path)")
        }
        do {
            try await write(handle)
            try handle.close()
            try Task.checkCancellation()
            // rename(2) replaces an earlier extract atomically.
            guard rename(partialURL.path, destURL.path) == 0 else {
                throw ExtractError.writeFailed("rename failed: \(String(cString: strerror(errno)))")
            }
            return destURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private static func partialPrefix(for destURL: URL) -> String {
        "\(destURL.deletingPathExtension().lastPathComponent)-"
    }

    /// Drops the on-disk extracted PDF for one book. Call when the loan
    /// is returned so a re-borrow doesn't reuse a stale extract against
    /// potentially different content. Best-effort.
    static func invalidate(bookIdentifier: String, account: String) {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return }
        try? FileManager.default.removeItem(at: url)
        // A partial file outlives its extract only when the app is killed
        // mid-write; return is the point at which it is known to be unused.
        let dir = url.deletingLastPathComponent()
        let prefix = partialPrefix(for: url)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
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
