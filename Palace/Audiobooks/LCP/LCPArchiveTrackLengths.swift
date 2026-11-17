//
//  LCPArchiveTrackLengths.swift
//  Palace
//
//  Resolves an LCP audiobook's per-track plaintext lengths from the archive
//  directly, so playback does not pay Readium's buffered tail probe for them.
//

#if LCP

import Foundation

/// The ZIP and AES-CBC arithmetic needed to learn a track's plaintext length
/// from the archive, without reading it through Readium's buffered resource.
///
/// Readium learns the length by reading an entry's last two AES blocks through
/// the archive's shared 6 MB buffer. Measured on device, one such 32-byte read
/// cost 17.8-35.5 MB of origin traffic and 2.0-9.2s of a chapter change: the
/// entry's tail is a whole chapter away from its audio, so it lands in a
/// different window, and the player's eight concurrent reads evict each other's
/// single shared window. Asking the origin for those 32 bytes costs one request.
///
/// The formula matches `LCPDecryptor.plainTextSizeTask`: the stored length minus
/// one AES block for the IV, minus the PKCS#7 padding, which is the last byte of
/// the deciphered final block. Kept as pure functions because the fork's own
/// history includes two fatal errors in three lines of this arithmetic
/// (`Data` slice indices, and an underflowing padding length).
enum LCPArchiveTrackLengths {
    static let aesBlockSize: UInt64 = 16

    /// What the central directory says about one entry.
    struct Entry: Equatable {
        let href: String
        let localHeaderOffset: UInt64
        /// The bytes as stored. For an LCP audio entry this is the ciphertext,
        /// because the resource is encrypted and then stored uncompressed.
        let storedLength: UInt64
        let isCompressed: Bool
    }

    /// Parses the central directory out of a tail read of the archive.
    ///
    /// `tailOffset` is where `tail` begins in the archive, so central-directory
    /// offsets taken from the end-of-central-directory record can be resolved
    /// into the buffer. Returns an empty array when the record is absent or the
    /// directory falls outside what was read, rather than guessing.
    static func entries(inArchiveTail tail: Data, tailStartsAt tailOffset: UInt64) -> [Entry] {
        guard let eocd = lastIndex(of: Data([0x50, 0x4B, 0x05, 0x06]), in: tail),
              eocd + 22 <= tail.count
        else { return [] }

        let directorySize = UInt64(u32(tail, at: eocd + 12))
        let directoryOffset = UInt64(u32(tail, at: eocd + 16))
        guard directoryOffset >= tailOffset else { return [] }

        var cursor = Int(directoryOffset - tailOffset)
        let directoryEnd = cursor + Int(directorySize)
        guard cursor >= 0, directoryEnd <= tail.count else { return [] }

        var found: [Entry] = []
        while cursor + 46 <= directoryEnd {
            guard tail[tail.startIndex + cursor] == 0x50,
                  tail[tail.startIndex + cursor + 1] == 0x4B,
                  tail[tail.startIndex + cursor + 2] == 0x01,
                  tail[tail.startIndex + cursor + 3] == 0x02
            else { break }

            let method = u16(tail, at: cursor + 10)
            let compressedSize = UInt64(u32(tail, at: cursor + 20))
            let uncompressedSize = UInt64(u32(tail, at: cursor + 24))
            let nameLength = Int(u16(tail, at: cursor + 28))
            let extraLength = Int(u16(tail, at: cursor + 30))
            let commentLength = Int(u16(tail, at: cursor + 32))
            let localHeaderOffset = UInt64(u32(tail, at: cursor + 42))

            let nameStart = tail.startIndex + cursor + 46
            guard nameStart + nameLength <= tail.endIndex else { break }
            let name = String(decoding: tail[nameStart ..< nameStart + nameLength])

            let compressed = method != 0
            found.append(Entry(
                href: name,
                localHeaderOffset: localHeaderOffset,
                storedLength: compressed ? compressedSize : uncompressedSize,
                isCompressed: compressed
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return found
    }

    /// Where an entry's bytes begin, given its local header.
    ///
    /// Read from the local header rather than computed from the central
    /// directory: the two records may carry different extra fields, and the
    /// local one is what the data actually follows.
    static func dataOffset(forLocalHeader header: Data, at localHeaderOffset: UInt64) -> UInt64? {
        guard header.count >= 30,
              header[header.startIndex] == 0x50,
              header[header.startIndex + 1] == 0x4B,
              header[header.startIndex + 2] == 0x03,
              header[header.startIndex + 3] == 0x04
        else { return nil }
        let nameLength = UInt64(u16(header, at: 26))
        let extraLength = UInt64(u16(header, at: 28))
        return localHeaderOffset + 30 + nameLength + extraLength
    }

    /// The archive range holding an entry's last two AES blocks, which is what
    /// the padding has to be read from.
    static func tailRange(dataOffset: UInt64, storedLength: UInt64) -> Range<UInt64>? {
        guard isValidCiphertextLength(storedLength) else { return nil }
        let start = dataOffset + storedLength - 2 * aesBlockSize
        return start ..< (dataOffset + storedLength)
    }

    /// `LCPDecryptor` refuses a ciphertext that is not two whole AES blocks or
    /// more; matching that keeps this from reporting a length the decryptor
    /// would then reject.
    static func isValidCiphertextLength(_ length: UInt64) -> Bool {
        length >= 2 * aesBlockSize && length % aesBlockSize == 0
    }

    /// The plaintext length, from the stored length and the deciphered tail.
    ///
    /// nil rather than a trap for every bad input: a padding byte larger than
    /// the data is exactly the shape that underflowed `UInt64` arithmetic in the
    /// fork's own history.
    static func plaintextLength(storedLength: UInt64, decipheredTail: Data) -> UInt64? {
        guard isValidCiphertextLength(storedLength),
              let padding = decipheredTail.last.map(UInt64.init),
              padding >= 1, padding <= aesBlockSize,
              storedLength >= aesBlockSize + padding
        else { return nil }
        return storedLength - aesBlockSize - padding
    }

    // MARK: - Little-endian readers

    private static func u16(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | UInt32(data[i + 1]) << 8
            | UInt32(data[i + 2]) << 16
            | UInt32(data[i + 3]) << 24
    }

    /// Last occurrence of `needle`, searched backwards because the
    /// end-of-central-directory record is at the end and a ZIP comment can
    /// contain the same bytes earlier.
    private static func lastIndex(of needle: Data, in haystack: Data) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var i = haystack.count - needle.count
        while i >= 0 {
            var matched = true
            for j in 0 ..< needle.count
            where haystack[haystack.startIndex + i + j] != needle[needle.startIndex + j] {
                matched = false
                break
            }
            if matched { return i }
            i -= 1
        }
        return nil
    }
}

private extension String {
    init(decoding bytes: Data) {
        self = String(data: Data(bytes), encoding: .utf8) ?? ""
    }
}

#endif
