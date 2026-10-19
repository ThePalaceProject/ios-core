//
//  LCPArchiveTrackLengthResolver.swift
//  Palace
//
//  Reads an LCP audiobook's track lengths from the archive with two small
//  ranged requests per track, in place of Readium's buffered tail probe.
//

#if LCP

import Foundation

/// Learns the plaintext length of each track of a streamed LCP audiobook.
///
/// Readium learns the same length by reading the entry's last two AES blocks
/// through the archive's shared 6 MB buffer. Measured on device, that 32-byte
/// read cost 17.8-35.5 MB of origin traffic and 2.0-9.2s of a chapter change,
/// because the entry's tail is a whole chapter away from its audio and the
/// player's eight concurrent reads evict each other's single window.
///
/// This asks the origin for the bytes it needs: the archive tail once, then a
/// local header and a 32-byte ciphertext tail per track. `LCPArchiveTrackLengths`
/// holds the arithmetic; this type decides which bytes to read and in what order.
struct LCPArchiveTrackLengthResolver: Sendable {
    /// Reads an absolute archive byte range. nil when the read fails.
    typealias ReadRange = @Sendable (Range<UInt64>) async -> Data?

    /// Deciphers LCP ciphertext — `LCPLicense.decipher` in production. nil when
    /// the licence cannot decipher the bytes.
    typealias Decipher = @Sendable (Data) -> Data?

    /// How much of the archive tail is read to find the central directory.
    ///
    /// Readium's own open reads 65,633 bytes of the tail and the caching client
    /// keeps them, so a read of this size is contained in bytes that are
    /// already local and normally costs no request.
    static let tailReadLength: UInt64 = 65_536

    /// How much of an entry's local header is read. Only its first 30 bytes
    /// carry the name and extra lengths; the rest is margin for a server that
    /// answers a shorter range than asked for.
    static let localHeaderReadLength: UInt64 = 128

    /// How many archive reads this resolution keeps in flight.
    static let defaultMaxConcurrentReads = 3

    /// What one resolution did, for the caller's report.
    ///
    /// Counted here rather than off the archive client: that client is shared
    /// with playback, so its counter attributes the loader's 6 MB windows to
    /// whatever happens to be running at the same time.
    struct Summary: Equatable {
        var resolved = 0
        var requests = 0
        var bytes = 0
    }

    let archiveLength: UInt64
    let readRange: ReadRange
    let decipher: Decipher

    /// Resolves the length of each named track, reporting each one as it lands,
    /// and returns what the resolution did.
    ///
    /// Two things decide the order. `nextDemanded` names the track a chapter
    /// load is waiting on, which is taken before anything else: a patron who
    /// resumes in the middle of a book needs that length first, and reading
    /// order would reach it last. Otherwise the order given stands, which is
    /// reading order.
    ///
    /// `maxConcurrentReads` bounds how many reads are open at once. Measured on
    /// device, 28 tracks took 47.0s for 70,016 bytes: the fill is bound by
    /// round trips, not bytes, and a chapter change inside that window still
    /// pays Readium's probe. The bound is low because the link is shared with
    /// the audio the patron is listening to.
    @discardableResult
    func resolveLengths(
        forHrefs hrefs: [String],
        maxConcurrentReads: Int = Self.defaultMaxConcurrentReads,
        nextDemanded: @escaping @Sendable () -> String? = { nil },
        report: @Sendable (_ href: String, _ length: UInt64) -> Void
    ) async -> Summary {
        var summary = Summary()
        guard !hrefs.isEmpty, archiveLength > 0 else { return summary }

        let directory = await readEntries(into: &summary)
        guard !directory.isEmpty else { return summary }

        var remaining = hrefs
        let width = max(1, maxConcurrentReads)

        return await withTaskGroup(of: TrackResolution.self) { group in
            var inFlight = 0
            while inFlight < width,
                  let next = Self.takeNext(from: &remaining, preferring: nextDemanded(), in: directory)
            {
                group.addTask { await self.resolution(forHref: next.href, entry: next.entry) }
                inFlight += 1
            }

            while let finished = await group.next() {
                inFlight -= 1
                summary.requests += finished.summary.requests
                summary.bytes += finished.summary.bytes
                if let length = finished.length {
                    report(finished.href, length)
                    summary.resolved += 1
                }
                // A cancelled resolution lets the tracks already in flight
                // finish — their bytes are paid for — and starts no others.
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                while inFlight < width,
                      let next = Self.takeNext(from: &remaining, preferring: nextDemanded(), in: directory)
                {
                    group.addTask { await self.resolution(forHref: next.href, entry: next.entry) }
                    inFlight += 1
                }
            }
            return summary
        }
    }

    /// One track's outcome, carried back to the caller's accumulator. A child
    /// cannot add to the parent's summary, so it counts its own reads and the
    /// parent adds them.
    private struct TrackResolution: Sendable {
        let href: String
        let length: UInt64?
        let summary: Summary
    }

    private func resolution(
        forHref href: String, entry: LCPArchiveTrackLengths.Entry
    ) async -> TrackResolution {
        var summary = Summary()
        let length = await plaintextLength(for: entry, into: &summary)
        return TrackResolution(href: href, length: length, summary: summary)
    }

    /// The next track to read: the demanded one if it is still outstanding,
    /// otherwise the first of those left. Hrefs the directory does not name are
    /// dropped here; they cost no read.
    private static func takeNext(
        from remaining: inout [String],
        preferring demanded: String?,
        in directory: [LCPArchiveTrackLengths.Entry]
    ) -> (href: String, entry: LCPArchiveTrackLengths.Entry)? {
        while !remaining.isEmpty {
            let index = demanded.flatMap { remaining.firstIndex(of: $0) } ?? remaining.startIndex
            let href = remaining.remove(at: index)
            if let entry = entry(forHref: href, in: directory) {
                return (href, entry)
            }
        }
        return nil
    }

    /// Every archive read goes through here, so the summary counts all of them
    /// and no caller can add one that the report misses.
    private func read(_ range: Range<UInt64>, into summary: inout Summary) async -> Data? {
        summary.requests += 1
        let data = await readRange(range)
        summary.bytes += data?.count ?? 0
        return data
    }

    /// The archive's central directory, read from its tail.
    private func readEntries(into summary: inout Summary) async -> [LCPArchiveTrackLengths.Entry] {
        let start = archiveLength > Self.tailReadLength ? archiveLength - Self.tailReadLength : 0
        guard let tail = await read(start ..< archiveLength, into: &summary) else { return [] }
        return LCPArchiveTrackLengths.entries(inArchiveTail: tail, tailStartsAt: start)
    }

    /// One entry's plaintext length: its local header, then its last two AES
    /// blocks.
    ///
    /// Every bound is checked against the archive's own length. A directory
    /// naming more bytes than the archive holds is a corrupt or foreign
    /// directory, and reading on that basis is how one archive's bytes are
    /// interpreted at another's offsets.
    private func plaintextLength(
        for entry: LCPArchiveTrackLengths.Entry, into summary: inout Summary
    ) async -> UInt64? {
        guard !entry.isCompressed,
              LCPArchiveTrackLengths.isValidCiphertextLength(entry.storedLength),
              entry.localHeaderOffset < archiveLength
        else { return nil }

        let headerEnd = min(entry.localHeaderOffset + Self.localHeaderReadLength, archiveLength)
        guard let header = await read(entry.localHeaderOffset ..< headerEnd, into: &summary),
              let dataOffset = LCPArchiveTrackLengths.dataOffset(
                  forLocalHeader: header, at: entry.localHeaderOffset
              ),
              let tailRange = LCPArchiveTrackLengths.tailRange(
                  dataOffset: dataOffset, storedLength: entry.storedLength
              ),
              tailRange.upperBound <= archiveLength,
              let ciphertext = await read(tailRange, into: &summary),
              ciphertext.count == Int(2 * LCPArchiveTrackLengths.aesBlockSize),
              let plaintext = decipher(ciphertext)
        else { return nil }

        return LCPArchiveTrackLengths.plaintextLength(
            storedLength: entry.storedLength, decipheredTail: plaintext
        )
    }

    /// The entry a reading-order href names.
    ///
    /// A manifest may spell the href rooted or percent-encoded while the ZIP
    /// entry carries the raw name, so an exact match is tried first and a
    /// normalised one second. Nothing looser: answering with another entry
    /// deciphers the wrong end of the archive.
    private static func entry(
        forHref href: String, in entries: [LCPArchiveTrackLengths.Entry]
    ) -> LCPArchiveTrackLengths.Entry? {
        if let exact = entries.first(where: { $0.href == href }) { return exact }
        let wanted = normalized(href)
        return entries.first { normalized($0.href) == wanted }
    }

    private static func normalized(_ href: String) -> String {
        var value = href.components(separatedBy: "#").first ?? href
        if value.hasPrefix("/") { value.removeFirst() }
        return value.removingPercentEncoding ?? value
    }
}

#endif
