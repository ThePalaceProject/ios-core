//
//  LCPArchiveTrackLengthsTests.swift
//  PalaceTests
//
//  The ZIP and AES-CBC arithmetic that replaces Readium's buffered tail probe.
//

#if LCP

import XCTest
@testable import Palace

/// This arithmetic decides which bytes of an encrypted archive are read and how
/// long a track is said to be, so an error here is wrong audio or a refused
/// read rather than a visible crash. The pinned fork's own history includes two
/// fatal errors in three lines of the padding calculation.
final class LCPArchiveTrackLengthsTests: XCTestCase {

    // MARK: - The plaintext length formula

    /// Matches `LCPDecryptor`: stored length, minus one AES block for the IV,
    /// minus the PKCS#7 padding taken from the last deciphered byte.
    func testPlaintextLength_subtractsTheIVAndThePadding() {
        let stored: UInt64 = 17_901_696
        let tail = Data(repeating: 0xAA, count: 15) + Data([7])

        XCTAssertEqual(
            LCPArchiveTrackLengths.plaintextLength(storedLength: stored, decipheredTail: tail),
            stored - 16 - 7,
            "a wrong length here is a truncated or over-read chapter"
        )
    }

    func testPlaintextLength_rejectsAPaddingOfZero() {
        XCTAssertNil(
            LCPArchiveTrackLengths.plaintextLength(
                storedLength: 4096,
                decipheredTail: Data(repeating: 0, count: 16)
            ),
            "PKCS#7 padding is 1 to 16; zero means the block did not decipher as padding"
        )
    }

    func testPlaintextLength_rejectsAPaddingLargerThanABlock() {
        XCTAssertNil(
            LCPArchiveTrackLengths.plaintextLength(
                storedLength: 4096,
                decipheredTail: Data(repeating: 0xFF, count: 16)
            ),
            "a padding byte of 255 is not a block's worth of padding, and trusting it underflows the length"
        )
    }

    func testPlaintextLength_rejectsACiphertextShorterThanTwoBlocks() {
        XCTAssertNil(
            LCPArchiveTrackLengths.plaintextLength(
                storedLength: 16,
                decipheredTail: Data(repeating: 0, count: 15) + Data([1])
            ),
            "the decryptor refuses this too; reporting a length it would reject moves the failure later"
        )
    }

    func testPlaintextLength_rejectsALengthThatIsNotAWholeNumberOfBlocks() {
        XCTAssertNil(
            LCPArchiveTrackLengths.plaintextLength(
                storedLength: 4095,
                decipheredTail: Data(repeating: 0, count: 15) + Data([1])
            ),
            "AES-CBC ciphertext is block-aligned; anything else is not this entry's ciphertext"
        )
    }

    func testPlaintextLength_withTheLargestLegalPadding() {
        XCTAssertEqual(
            LCPArchiveTrackLengths.plaintextLength(
                storedLength: 1024,
                decipheredTail: Data(repeating: 16, count: 16)
            ),
            1024 - 16 - 16,
            "a full block of padding is legal PKCS#7 and must not be refused"
        )
    }

    // MARK: - Which bytes to read

    func testTailRange_isTheLastTwoBlocksOfTheEntry() {
        let range = LCPArchiveTrackLengths.tailRange(dataOffset: 1_000, storedLength: 4_096)
        XCTAssertEqual(
            range, (1_000 + 4_096 - 32) ..< (1_000 + 4_096),
            "the padding lives in the final block, and CBC needs the one before it to decipher it"
        )
    }

    func testTailRange_refusesAnEntryTooShortToHoldAnIVAndABlock() {
        XCTAssertNil(
            LCPArchiveTrackLengths.tailRange(dataOffset: 0, storedLength: 16),
            "there is no preceding block to decipher against"
        )
    }

    // MARK: - Locating an entry's bytes

    /// The local header's extra field can differ in length from the central
    /// directory's, so the data offset has to come from the local one.
    func testDataOffset_usesTheLocalHeadersOwnNameAndExtraLengths() {
        let header = Self.localHeader(nameLength: 44, extraLength: 9)
        XCTAssertEqual(
            LCPArchiveTrackLengths.dataOffset(forLocalHeader: header, at: 5_000),
            5_000 + 30 + 44 + 9,
            "computing this from the central directory's extra length reads the wrong bytes"
        )
    }

    func testDataOffset_refusesSomethingThatIsNotALocalHeader() {
        XCTAssertNil(
            LCPArchiveTrackLengths.dataOffset(
                forLocalHeader: Data(repeating: 0, count: 40),
                at: 0
            ),
            "without the signature there is no reason to believe the length fields"
        )
    }

    // MARK: - Reading the central directory

    func testEntries_readsEachRecordsNameLengthAndCompression() {
        let audio = Self.centralDirectoryRecord(
            name: "chapter-one.MP3.mp3", method: 0,
            compressedSize: 17_901_696, uncompressedSize: 17_901_696, localHeaderOffset: 226_602
        )
        let manifest = Self.centralDirectoryRecord(
            name: "manifest.json", method: 8,
            compressedSize: 3_183, uncompressedSize: 9_001, localHeaderOffset: 749_764_122
        )
        let directory = audio + manifest
        // The tail begins part-way into the archive, as a real tail read does.
        let tailOffset: UInt64 = 1_000
        let tail = Data(repeating: 0, count: 64)
            + directory
            + Self.endOfCentralDirectory(
                entryCount: 2,
                directorySize: UInt64(directory.count),
                directoryOffset: tailOffset + 64
            )

        let entries = LCPArchiveTrackLengths.entries(inArchiveTail: tail, tailStartsAt: tailOffset)

        XCTAssertEqual(entries.count, 2, "every record in the directory must be read")
        XCTAssertEqual(entries[0].href, "chapter-one.MP3.mp3")
        XCTAssertEqual(
            entries[0].storedLength, 17_901_696,
            "a stored entry's stored length is its uncompressed size, which is the ciphertext"
        )
        XCTAssertFalse(entries[0].isCompressed)
        XCTAssertEqual(entries[0].localHeaderOffset, 226_602)
        XCTAssertEqual(
            entries[1].storedLength, 3_183,
            "a deflated entry's stored length is its compressed size"
        )
        XCTAssertTrue(
            entries[1].isCompressed,
            "a deflated entry cannot have its length derived this way and must be distinguishable"
        )
    }

    func testEntries_whenTheDirectoryLiesOutsideTheTailRead_reportsNothing() {
        let record = Self.centralDirectoryRecord(
            name: "a.mp3", method: 0,
            compressedSize: 32, uncompressedSize: 32, localHeaderOffset: 0
        )
        let tail = record + Self.endOfCentralDirectory(
            entryCount: 1,
            directorySize: UInt64(record.count),
            directoryOffset: 5   // before the tail began
        )

        XCTAssertEqual(
            LCPArchiveTrackLengths.entries(inArchiveTail: tail, tailStartsAt: 10_000), [],
            "guessing at a directory that was not read would parse arbitrary audio bytes as records"
        )
    }

    func testEntries_withNoEndRecord_reportsNothing() {
        XCTAssertEqual(
            LCPArchiveTrackLengths.entries(
                inArchiveTail: Data(repeating: 0x41, count: 512), tailStartsAt: 0
            ),
            [],
            "no end-of-central-directory record means this is not the end of a ZIP"
        )
    }


    // MARK: - Against a real archive's bytes

    /// The builders above could encode the same misunderstanding as the parser.
    /// This is the real central directory of a production LCP audiobook, 4,647
    /// bytes plus its end record, taken from the archive at
    /// storage.googleapis.com/hub-lcp-prod-northamerica. 52 entries: 49 stored
    /// audio tracks, a stored cover, a tiny stored first track, and a deflated
    /// manifest.
    func testEntries_againstARealLCPAudiobooksCentralDirectory() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: Self.realCentralDirectoryBase64))
        let directoryOffset: UInt64 = 749_767_364

        let entries = LCPArchiveTrackLengths.entries(
            inArchiveTail: blob, tailStartsAt: directoryOffset
        )

        XCTAssertEqual(entries.count, 52, "the archive's own end record declares 52 entries")

        let audio = entries.filter { !$0.isCompressed && $0.storedLength > 1_048_576 }
        XCTAssertEqual(audio.count, 49, "49 of the entries are the chapters")
        XCTAssertTrue(
            audio.allSatisfy { LCPArchiveTrackLengths.isValidCiphertextLength($0.storedLength) },
            "every chapter's stored length must be a whole number of AES blocks, or it is not the ciphertext this reads"
        )

        let manifest = try XCTUnwrap(entries.first { $0.href == "manifest.json" })
        XCTAssertTrue(
            manifest.isCompressed,
            "the manifest is deflated, so its length cannot be derived from the stored size"
        )
        XCTAssertEqual(manifest.storedLength, 3_183)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.localHeaderOffset, 0, "the first entry's data starts the archive")
        XCTAssertEqual(first.storedLength, 226_512)
    }

    private static let realCentralDirectoryBase64 =
            "UEsBAhQAFAAIAAAAAAAAAOm13Z7QdAMA0HQDACwAAAAAAAAAAAAAAAAAAAAAADliNDAzNjg5LTQ3ODItNDU2Ni1hNzM0LTgzZjU4" +
            "MDZmMjg1MC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAACIVCJKAKBEBgCgRASwAAAAAAAAAAAAAAAAAKnUDADU3OWJmMDQ0LTA0ZTEt" +
            "NDU5Mi04ZmI4LTc4M2ZhMzBhODhkZi5NUDMubXAzUEsBAhQAFAAIAAAAAAAAADfmF8OQzzYBkM82ASwAAAAAAAAAAAAAAAAABJ4U" +
            "ATBmNDM5N2E1LTI5ODMtNDlmYS05OTBkLWUwOTFhNTY0OThlNy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAADnBzDbASv4AwEr+ACwA" +
            "AAAAAAAAAAAAAAAA7m1LAmM4YjY5YjViLWNmZTYtNGM4NS04MjdiLWY1MjM5YjQxNjc3Yy5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AANzvSbAY6EBwGOhASwAAAAAAAAAAAAAAAAACLlJAzA1Njc2NjI3LWViNDAtNDk1NC1iMDc2LTBkNGQ0OTM2MzM5ZC5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAACdCyOkwldIAMJXSACwAAAAAAAAAAAAAAAAAIh3rBDQ4YWQ4ZDQyLTM1MGItNGU1MC04MTc4LTcwNWQ0" +
            "NmViYWUzYi5NUDMubXAzUEsBAhQAFAAIAAAAAAAAADT74v9QnnUAUJ51ACwAAAAAAAAAAAAAAAAArLK9BTlhMjJkOWEwLWE3NmQt" +
            "NDBmYi1iMWY0LTMyYjFhOWViZjVkMC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAI5BFIZg8ZUAYPGVACwAAAAAAAAAAAAAAAAAVlEz" +
            "BjNlNmZkYWU2LTE3ODMtNGE0Yi1hZDM3LTBhMDM4ZmUxZDViOS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAP4X28awplIBsKZSASwA" +
            "AAAAAAAAAAAAAAAAEEPJBjAyYmI4ODhjLTZjMjItNGFjMS1iZDA3LTE3M2JiMjAyNzFkYy5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AMkyVFOA6coAgOnKACwAAAAAAAAAAAAAAAAAGuobCGE2MDExMmQ0LWQ0NTktNDFhYi05MzE2LTQzOWMzMWVmNGQ1NS5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAELp5/9g0bAAYNGwACwAAAAAAAAAAAAAAAAA9NPmCGU5YjRlNGI5LWJhMzgtNDgwZS05Y2Q0LWIyM2M4" +
            "NWJjNDlmOS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAALWGuPuQRd4AkEXeACwAAAAAAAAAAAAAAAAArqWXCWI5YmYwMzkwLTIwM2Qt" +
            "NDI0Ni1hMjBlLTExNDQ3NTkwMzRlMy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAADuXFSQgKaQAICmkACwAAAAAAAAAAAAAAAAAmOt1" +
            "CjdkZmY3ZjFjLWVlNTAtNDIwYy05NGY5LTM1ZTJkYzE4NGUwOC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAADzBR1UQq2kAEKtpACwA" +
            "AAAAAAAAAAAAAAAAEhUaCzAxZjJkNmQwLWE1ZDgtNDZjYi1iNDY1LWQ4ZTA0YjNkMmU3YS5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AJvmeTWw4sMAsOLDACwAAAAAAAAAAAAAAAAAfMCDCzk1ODk4MjQ1LWM5NjYtNGI0Zi1hOThiLTYxMjEyNDdiZTk4OS5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAKGuTHyAew4BgHsOASwAAAAAAAAAAAAAAAAAhqNHDDRkYzJlNzk4LWQzYTEtNDNiOS1iODJiLWE2ZjRl" +
            "ZjJiNjQ4ZC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAAn+2L/wxHEA8MRxACwAAAAAAAAAAAAAAAAAYB9WDThhZmI5YmQ1LTQxNzct" +
            "NGIwYy05OWJiLWI4YzBkZGEyOWEwYy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAABGkFNwwBF8AMARfACwAAAAAAAAAAAAAAAAAquTH" +
            "DTJhYjliZTQwLTkxZmUtNDlkNC05NWUzLWFjZTcyNGQwYzFmMC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAIXscVaAtUEAgLVBACwA" +
            "AAAAAAAAAAAAAAAANOkmDjIzYjMxMzVhLTZlODAtNGRlYS04MDg5LTJiMDQxNzNiZmJjOC5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AB/KdrnwP80A8D/NACwAAAAAAAAAAAAAAAAADp9oDmExOWJhZjk5LTA4MWUtNGFmOC05NmEyLWQ0NzI4N2IwNWE4Zi5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAIBZ8wNQlI0BUJSNASwAAAAAAAAAAAAAAAAAWN81DzVlZGIyZWU3LTAyOGItNGViNi1iNjEwLWZiYzdm" +
            "YzlmYzBmMi5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAKGxcwGg04UAoNOFACwAAAAAAAAAAAAAAAAAAnTDEDdlMTlhNjZmLWFkMjEt" +
            "NDQ0MC1hNTJhLTVjMTUwY2MyM2M1NS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAOZ9ylpgAC8BYAAvASwAAAAAAAAAAAAAAAAA/EdJ" +
            "ETZlNDA4MDc2LTc5YWQtNDRjZS05N2EzLTIzMTQwOTIwMjhkZC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAALljtImw15UAsNeVACwA" +
            "AAAAAAAAAAAAAAAAtkh4EjFlZDdhNzkxLWEyYTEtNDRkMS05ZmVjLWFiY2NjZDI4YWQwYy5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AOvlPi9gDigBYA4oASwAAAAAAAAAAAAAAAAAwCAOEzEyZjgwYWY4LTBkNGYtNDE0NC1hOGMwLTM2MDRhNTc2ZmFjYy5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAO9M0dUgJykBICcpASwAAAAAAAAAAAAAAAAAei82FDkyNzBhZDI3LWUwYmMtNDYyZS1iNzIxLTU1NjAz" +
            "MGIxYmI1ZS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAPs9BvKAm8EBgJvBASwAAAAAAAAAAAAAAAAA9FZfFTc0OWFjNTg3LWI3Zjkt" +
            "NDAzZC05YTBlLTg5MmJhZDU1NDgyMy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAPKBFEDQsd0A0LHdACwAAAAAAAAAAAAAAAAAzvIg" +
            "FzgzNWU0NThhLTY3MDctNDI5Zi1iZjVjLTczNjU2ZTViYjEwMi5NUDMubXAzUEsBAhQAFAAIAAAAAAAAANyBzJMwMVABMDFQASwA" +
            "AAAAAAAAAAAAAAAA+KT+F2QxOGFiYzgyLWQ0N2EtNGI0MS05ZDM4LWM2MDQ1MzM2OTJmZi5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AO7xOv3w88UA8PPFACwAAAAAAAAAAAAAAAAAgtZOGWQyYWY5NjRkLWIzMzQtNGNhYS1hZGMwLTdiYTRiYzY2MDBjYS5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAGoM++TApo0BwKaNASwAAAAAAAAAAAAAAAAAzMoUGjMzNzk5NDljLWMxOTUtNGEzMi05ZGY1LWEyMTBj" +
            "MGU1MWVmNC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAANpAVBMQObYAEDm2ACwAAAAAAAAAAAAAAAAA5nGiGzUwYWNmMWRjLTYyNzkt" +
            "NDljMy1hY2UzLTJiYjY1ODY0NWFmOC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAMOvgEWQJCwBkCQsASwAAAAAAAAAAAAAAAAAUKtY" +
            "HDAyNDRiYjVjLWVkNDktNGQzYy1hMzY2LTMyNTRjMWZiNmNjNy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAAj7b5PQZPIA0GTyACwA" +
            "AAAAAAAAAAAAAAAAOtCEHWUzYTI3OGI1LWY2NzUtNGQ0YS05YjgzLTBjZDkyNGRmM2ZjMC5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AMZ8WF+wk6IAsJOiACwAAAAAAAAAAAAAAAAAZDV3HjgzMWU3ZTkzLTA5MTktNGJkMy1iNzUwLTMxZDc4YTRhZGEwOS5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAIofBU4wTyUBME8lASwAAAAAAAAAAAAAAAAAbskZHzUyMmNiZDhiLTVkMGMtNGRkMy1iMDA5LTZjNGU4" +
            "NjU4OTYxZi5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAJCBjV/Al+gAwJfoACwAAAAAAAAAAAAAAAAA+Bg/IDRiZjFlYTY3LTE5MDAt" +
            "NDQ0MS04MWE5LTkwMzJhZjMzYWNmNC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAO2jqN0gFOQAIBTkACwAAAAAAAAAAAAAAAAAErEn" +
            "ITFiYjg4NjI2LTVkYTMtNGE4ZS05ZTVmLTc0M2Y4ZTNjZmIwMy5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAFIzAX6Q074AkNO+ACwA" +
            "AAAAAAAAAAAAAAAAjMULIjFhOWU2ZTgyLTg0ZWYtNDQ3NC05Zjg4LWMyNjYyODZhMmUyYy5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AInJ1tBgF84AYBfOACwAAAAAAAAAAAAAAAAAdpnKIjdiMjY5ZjY5LTNlNjEtNDM3MS04NzVjLWRkMjdlN2QyZDBjMy5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAANRgfsugT1QBoE9UASwAAAAAAAAAAAAAAAAAMLGYIzc3ZDYyNDViLWQ3YzMtNDFiMy05YmFkLTFmZjU0" +
            "MDc0ZTQ5MS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAHa0KLKATt4AgE7eACwAAAAAAAAAAAAAAAAAKgHtJDk3YjI3NDVlLTg4OTMt" +
            "NDliNy05MDhhLWRhYzE1NjE1YzUxYS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAELtX7yQOE0BkDhNASwAAAAAAAAAAAAAAAAABFDL" +
            "JWRmMWEzYTE2LTZjZmMtNGJkNS04MjQ1LTUyNjUzNGMyMjE2MC5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAJNY6qDAjCoBwIwqASwA" +
            "AAAAAAAAAAAAAAAA7ogYJzM1OGJiMGJhLWU2MjctNGQxMy04Y2IxLTdkMmI1ZGMzYzUwMi5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "ALTEwr5g3AQBYNwEASwAAAAAAAAAAAAAAAAACBZDKGU4MjdlOWQyLTBhNzQtNDg0Ni1iZWM5LTg2N2FkMzIwNDcwMC5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAADULSCdgmNAAYJjQACwAAAAAAAAAAAAAAAAAwvJHKTNhYzcwNjJhLTUwYzktNDNlZS04NGM2LTE3ZWQ3" +
            "NjBmYTEwZS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAABjs9sBwVX4AcFV+ACwAAAAAAAAAAAAAAAAAfIsYKjgxMmJhMjY0LWE5Y2Yt" +
            "NGEwZi1iNmYxLTVlNTFlYWQxZDkxOS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAGQnthLw210B8NtdASwAAAAAAAAAAAAAAAAARuGW" +
            "KjYwYzcxNWExLTEzNWItNDBlMy05ZTE1LWY4NjY4ZGMzZDE3ZS5NUDMubXAzUEsBAhQAFAAIAAAAAAAAAHFg74vQpooA0KaKACwA" +
            "AAAAAAAAAAAAAAAAkL30KzFiNjRkOGFiLTQ4ZTktNGVhOC1hNjZhLWM4MTU5MmVmYTFkZi5NUDMubXAzUEsBAhQAFAAIAAAAAAAA" +
            "AETtw+gQyCgAEMgoACwAAAAAAAAAAAAAAAAAumR/LGMzYjViMWUzLWM4NWQtNGJjZC1iNWI4LThjNzhlZDcwMDRmZC5NUDMubXAz" +
            "UEsBAhQAFAAIAAAAAAAAAPMpIt2eUAgAnlAIACoAAAAAAAAAAAAAAAAAJC2oLDNlODgyNmY5OWQwN2NjNWU3NTA0ZTZmYzI3YTMz" +
            "OTgwMTkyYzQyLmpwZ1BLAQIUABQACAAIAAAAAACMPdOibwwAAG5LAAANAAAAAAAAAAAAAAAAABp+sCxtYW5pZmVzdC5qc29uUEsF" +
            "BgAAAAA0ADQAJxIAAMSKsCwAAA=="

    // MARK: - Builders

    private static func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private static func centralDirectoryRecord(
        name: String, method: UInt16,
        compressedSize: UInt32, uncompressedSize: UInt32, localHeaderOffset: UInt32
    ) -> Data {
        let nameBytes = Data(name.utf8)
        var d = Data([0x50, 0x4B, 0x01, 0x02])
        d += u16(20) + u16(20) + u16(0) + u16(method)
        d += u16(0) + u16(0)                       // time, date
        d += u32(0)                                // crc
        d += u32(compressedSize) + u32(uncompressedSize)
        d += u16(UInt16(nameBytes.count)) + u16(0) + u16(0)
        d += u16(0) + u16(0) + u32(0)
        d += u32(localHeaderOffset)
        d += nameBytes
        return d
    }

    private static func localHeader(nameLength: UInt16, extraLength: UInt16) -> Data {
        var d = Data([0x50, 0x4B, 0x03, 0x04])
        d += u16(20) + u16(0) + u16(0)
        d += u16(0) + u16(0)
        d += u32(0) + u32(0) + u32(0)
        d += u16(nameLength) + u16(extraLength)
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

#endif
