//
//  LCPSyntheticArchive.swift
//  PalaceTests
//
//  A byte blob laid out like a streamed LCP audiobook archive, served a range
//  at a time, for the tests that read track lengths out of one.
//

#if LCP

import Foundation

/// Three stored tracks, a track whose declared size runs past the end, and a
/// deflated manifest, laid out as a ZIP: local header then data for each entry,
/// the central directory after them, and the end record last.
///
/// The local headers carry an extra field the central records do not, so a data
/// offset computed from the wrong record lands in the wrong place — which is
/// the mistake the production code documents and must not make.
enum LCPSyntheticArchive {

    struct Entry {
        let name: String
        let localHeaderOffset: UInt64
        let localExtraLength: UInt16
        /// The bytes as stored, which for a stored audio entry is the ciphertext.
        let storedLength: UInt64
        /// The PKCS#7 padding byte planted in the entry's last block. The
        /// double's decipher is the identity, so this byte is what the
        /// production code reads back as the padding.
        let padding: UInt8
        let method: UInt16

        var dataOffset: UInt64 {
            localHeaderOffset + 30 + UInt64(name.utf8.count) + UInt64(localExtraLength)
        }

        /// What the arithmetic must report for this entry.
        var plaintextLength: UInt64 { storedLength - 16 - UInt64(padding) }
    }

    static let trackA = Entry(
        name: "track-a.mp3", localHeaderOffset: 0, localExtraLength: 9,
        storedLength: 4_096, padding: 7, method: 0
    )
    static let trackB = Entry(
        name: "track-b.mp3", localHeaderOffset: 5_000, localExtraLength: 0,
        storedLength: 2_048, padding: 16, method: 0
    )
    /// Its name holds a space, so a manifest may spell its href percent-encoded.
    static let trackC = Entry(
        name: "track c.mp3", localHeaderOffset: 8_000, localExtraLength: 4,
        storedLength: 1_024, padding: 3, method: 0
    )
    /// Declares more bytes than the archive holds, as a corrupt or foreign
    /// central directory would.
    static let overrun = Entry(
        name: "track-overrun.mp3", localHeaderOffset: 11_000, localExtraLength: 0,
        storedLength: 1_048_576, padding: 1, method: 0
    )
    /// Its ciphertext ends at the archive's final byte, which is inside the
    /// archive and must be read, not refused.
    static let exactFit = Entry(
        name: "track-exact.mp3", localHeaderOffset: 11_507, localExtraLength: 0,
        storedLength: 2_448, padding: 5, method: 0
    )
    /// Its local header starts where the archive ends, so there is nothing of
    /// it to read.
    static let atEnd = Entry(
        name: "track-at-end.mp3", localHeaderOffset: 14_000, localExtraLength: 0,
        storedLength: 1_024, padding: 1, method: 0
    )
    static let manifest = Entry(
        name: "manifest.json", localHeaderOffset: 10_000, localExtraLength: 0,
        storedLength: 300, padding: 0, method: 8
    )

    static let directoryOffset: UInt64 = 12_000
    static let length: UInt64 = 14_000

    static func make() -> LCPArchiveReadDouble {
        let planned = [trackA, trackB, trackC, overrun, exactFit, atEnd, manifest]
        var bytes = Data(repeating: 0, count: Int(length))

        for entry in planned {
            // An entry whose header or data falls outside the archive is still
            // declared in the directory — that is the point of it — so only the
            // bytes that fit are laid down.
            if entry.dataOffset <= length {
                splice(localHeader(name: entry.name, extraLength: entry.localExtraLength),
                       at: entry.localHeaderOffset, into: &bytes)
            }
            guard entry.dataOffset + entry.storedLength <= length else { continue }
            splice(
                Data(repeating: 0xAB, count: 31) + Data([entry.padding]),
                at: entry.dataOffset + entry.storedLength - 32,
                into: &bytes
            )
        }

        var directory = Data()
        for entry in planned {
            directory += centralDirectoryRecord(
                name: entry.name, method: entry.method,
                size: UInt32(entry.storedLength),
                localHeaderOffset: UInt32(entry.localHeaderOffset)
            )
        }
        splice(directory, at: directoryOffset, into: &bytes)
        splice(
            endOfCentralDirectory(
                entryCount: UInt16(planned.count),
                directorySize: UInt64(directory.count),
                directoryOffset: directoryOffset
            ),
            at: directoryOffset + UInt64(directory.count),
            into: &bytes
        )

        return LCPArchiveReadDouble(bytes: bytes)
    }

    // MARK: - ZIP records

    private static func splice(_ piece: Data, at offset: UInt64, into bytes: inout Data) {
        let start = Int(offset)
        bytes.replaceSubrange(start ..< start + piece.count, with: piece)
    }

    private static func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private static func centralDirectoryRecord(
        name: String, method: UInt16, size: UInt32, localHeaderOffset: UInt32
    ) -> Data {
        let nameBytes = Data(name.utf8)
        var d = Data([0x50, 0x4B, 0x01, 0x02])
        d += u16(20) + u16(20) + u16(0) + u16(method)
        d += u16(0) + u16(0)
        d += u32(0)
        d += u32(size) + u32(size)
        d += u16(UInt16(nameBytes.count)) + u16(0) + u16(0)
        d += u16(0) + u16(0) + u32(0)
        d += u32(localHeaderOffset)
        d += nameBytes
        return d
    }

    private static func localHeader(name: String, extraLength: UInt16) -> Data {
        let nameBytes = Data(name.utf8)
        var d = Data([0x50, 0x4B, 0x03, 0x04])
        d += u16(20) + u16(0) + u16(0)
        d += u16(0) + u16(0)
        d += u32(0) + u32(0) + u32(0)
        d += u16(UInt16(nameBytes.count)) + u16(extraLength)
        d += nameBytes
        d += Data(repeating: 0, count: Int(extraLength))
        return d
    }

    private static func endOfCentralDirectory(
        entryCount: UInt16, directorySize: UInt64, directoryOffset: UInt64
    ) -> Data {
        var d = Data([0x50, 0x4B, 0x05, 0x06])
        d += u16(0) + u16(0) + u16(entryCount) + u16(entryCount)
        d += u32(UInt32(directorySize)) + u32(UInt32(directoryOffset))
        d += u16(0)
        return d
    }
}

/// Serves ranges of the synthetic archive and records every range asked for.
final class LCPArchiveReadDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [Range<UInt64>] = []

    var bytes: Data
    /// What the archive claims to be. Usually its real size; raised in the
    /// test that pins where a large archive's tail read starts.
    var declaredLength: UInt64
    /// A read starting here fails, as a dropped connection would.
    var failReadsAt: UInt64?
    /// Called before each range is served.
    var onRead: (@Sendable (Range<UInt64>) -> Void)?
    /// Awaited before each range is served, so a test can hold a read open and
    /// observe how many run at once.
    var onReadAsync: (@Sendable (Range<UInt64>) async -> Void)?

    init(bytes: Data) {
        self.bytes = bytes
        self.declaredLength = UInt64(bytes.count)
    }

    var reads: [Range<UInt64>] {
        lock.withLock { requested }
    }

    func read(_ range: Range<UInt64>) async -> Data? {
        // Recorded and read back through `withLock` rather than `lock()`:
        // `NSLock.lock` is unavailable from an async context.
        let (failAt, blob, handler, asyncHandler) = record(range)
        handler?(range)
        await asyncHandler?(range)
        guard range.lowerBound != failAt else { return nil }
        let start = Int(range.lowerBound)
        let end = min(Int(range.upperBound), blob.count)
        guard start < end else { return nil }
        return blob.subdata(in: start ..< end)
    }

    private func record(
        _ range: Range<UInt64>
    ) -> (
        UInt64?,
        Data,
        (@Sendable (Range<UInt64>) -> Void)?,
        (@Sendable (Range<UInt64>) async -> Void)?
    ) {
        lock.withLock {
            requested.append(range)
            return (failReadsAt, bytes, onRead, onReadAsync)
        }
    }
}

#endif
