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

    let archiveLength: UInt64
    let readRange: ReadRange
    let decipher: Decipher

    /// Resolves the length of each named track, reporting each one as it lands.
    ///
    /// Serial, and in the order given: the tracks are reported in reading order
    /// so the chapters the patron reaches first are known first, and the player
    /// keeps the link it is streaming audio over.
    func resolveLengths(
        forHrefs hrefs: [String],
        report: @Sendable (_ href: String, _ length: UInt64) -> Void
    ) async {
        guard !hrefs.isEmpty, archiveLength > 0 else { return }

        let directory = await readEntries()
        guard !directory.isEmpty else { return }

        for href in hrefs {
            if Task.isCancelled { return }
            guard let entry = Self.entry(forHref: href, in: directory),
                  let length = await plaintextLength(for: entry)
            else { continue }
            report(href, length)
        }
    }

    /// The archive's central directory, read from its tail.
    private func readEntries() async -> [LCPArchiveTrackLengths.Entry] {
        let start = archiveLength > Self.tailReadLength ? archiveLength - Self.tailReadLength : 0
        guard let tail = await readRange(start ..< archiveLength) else { return [] }
        return LCPArchiveTrackLengths.entries(inArchiveTail: tail, tailStartsAt: start)
    }

    /// One entry's plaintext length: its local header, then its last two AES
    /// blocks.
    ///
    /// Every bound is checked against the archive's own length. A directory
    /// naming more bytes than the archive holds is a corrupt or foreign
    /// directory, and reading on that basis is how one archive's bytes are
    /// interpreted at another's offsets.
    private func plaintextLength(for entry: LCPArchiveTrackLengths.Entry) async -> UInt64? {
        guard !entry.isCompressed,
              LCPArchiveTrackLengths.isValidCiphertextLength(entry.storedLength),
              entry.localHeaderOffset < archiveLength
        else { return nil }

        let headerEnd = min(entry.localHeaderOffset + Self.localHeaderReadLength, archiveLength)
        guard let header = await readRange(entry.localHeaderOffset ..< headerEnd),
              let dataOffset = LCPArchiveTrackLengths.dataOffset(
                  forLocalHeader: header, at: entry.localHeaderOffset
              ),
              let tailRange = LCPArchiveTrackLengths.tailRange(
                  dataOffset: dataOffset, storedLength: entry.storedLength
              ),
              tailRange.upperBound <= archiveLength,
              let ciphertext = await readRange(tailRange),
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
