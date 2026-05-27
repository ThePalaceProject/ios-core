//
//  ReadiumPDFTOCCache.swift
//  Palace
//
//  Disk-backed cache of TOC + page count snapshots for Readium-backed
//  PDFs. Lets a cold-app re-open of the same LCP PDF skip the entire
//  `publication.tableOfContents()` + `publication.positions()` round
//  trip — both calls force Readium to read the PDF cross-reference
//  table and outline through the LCP content protection layer, which
//  triggers the dominant AES-decrypt loop on large Marketplace
//  containers (the hundreds of `Successfully decrypted 2064 -> 2048`
//  log lines).
//
//  Cache layout, per-account:
//
//      <accountDir>/registry/pdf-toc/<bookIdentifierSHA256>.json
//
//  Cache invariant: the LCP container for a given book identifier is
//  immutable for the loan window — the same SHA256(identifier) is a
//  stable filename and the cached TOC matches the on-disk file. On
//  return/re-borrow the registry path changes, so we don't have to
//  hand-invalidate.
//
//  Errors are non-fatal: a read miss or write failure just means we
//  fall back to the in-memory-only behavior (re-decrypt the cross-ref
//  on the next open). No correctness impact.
//

import Foundation
import PalaceLogging

enum ReadiumPDFTOCCache {

    /// Codable record matching the in-memory `(toc, pageCount)` tuple.
    private struct Snapshot: Codable {
        let toc: [TPPPDFLocation]
        let pageCount: Int
        let schemaVersion: Int
    }

    /// Bumped on schema changes so stale on-disk cache files are
    /// ignored after an upgrade rather than mis-decoded into the new
    /// shape.
    private static let currentSchemaVersion = 1

    // MARK: - Public API

    /// Reads a previously persisted TOC snapshot for the given book.
    /// Returns nil on miss, decode error, or schema mismatch.
    static func read(bookIdentifier: String, account: String) -> (toc: [TPPPDFLocation], pageCount: Int)? {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == currentSchemaVersion else {
                Log.debug(#file, "TOC cache schema mismatch (\(snapshot.schemaVersion) ≠ \(currentSchemaVersion)) — ignoring")
                return nil
            }
            return (snapshot.toc, snapshot.pageCount)
        } catch {
            Log.warn(#file, "TOC cache read failed for \(bookIdentifier): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes a TOC snapshot to disk. Best-effort — failures are logged
    /// but not surfaced to callers, since the in-memory snapshot is
    /// still authoritative for the current app session.
    static func write(toc: [TPPPDFLocation], pageCount: Int, bookIdentifier: String, account: String) {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let snapshot = Snapshot(toc: toc, pageCount: pageCount, schemaVersion: currentSchemaVersion)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warn(#file, "TOC cache write failed for \(bookIdentifier): \(error.localizedDescription)")
        }
    }

    /// Drops the on-disk snapshot for one book. Call when the loan is
    /// returned so a re-borrow doesn't reuse stale TOC against
    /// potentially different content. Best-effort.
    static func invalidate(bookIdentifier: String, account: String) {
        guard let url = fileURL(bookIdentifier: bookIdentifier, account: account) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Path

    /// `<accountDir>/registry/pdf-toc/<sha256(bookIdentifier)>.json`.
    /// Returns nil if the account directory can't be resolved.
    private static func fileURL(bookIdentifier: String, account: String) -> URL? {
        guard let accountDir = TPPBookContentMetadataFilesHelper.directory(for: account) else { return nil }
        let hashed = bookIdentifier.sha256()
        return accountDir
            .appendingPathComponent("registry")
            .appendingPathComponent("pdf-toc")
            .appendingPathComponent("\(hashed).json")
    }
}
