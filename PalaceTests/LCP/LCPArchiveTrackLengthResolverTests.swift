//
//  LCPArchiveTrackLengthResolverTests.swift
//  PalaceTests
//
//  The read plan that replaces Readium's buffered tail probe.
//

#if LCP

import XCTest
@testable import Palace

/// This type decides which bytes of a 715 MB encrypted archive are fetched to
/// learn a track's length. A wrong range is either a chapter that will not play
/// or the 17.8-35.5 MB of origin traffic this exists to remove, so each test
/// asserts the bytes asked for as well as the length reported.
final class LCPArchiveTrackLengthResolverTests: XCTestCase {

    private typealias Archive = LCPSyntheticArchive

    // MARK: - The read plan

    /// The whole point of the change: a track's length costs the archive tail
    /// once, then a local header and 32 bytes of ciphertext per track.
    func testResolveLengths_readsTheTailOnceAndTwoSmallRangesPerTrack() async {
        let archive = Archive.make()

        let reported = await resolve(["track-a.mp3", "track-b.mp3"], in: archive)

        XCTAssertEqual(
            reported,
            ["track-a.mp3": Archive.trackA.plaintextLength,
             "track-b.mp3": Archive.trackB.plaintextLength],
            "the length is the stored ciphertext minus the IV block and the PKCS#7 padding"
        )
        XCTAssertEqual(
            archive.reads.count, 5,
            "one tail read, then a local header and a ciphertext tail for each of the two tracks"
        )
        XCTAssertEqual(
            archive.reads.first, 0 ..< Archive.length,
            "this archive is shorter than the tail read, so the whole of it is the tail"
        )
        XCTAssertEqual(
            Array(archive.reads.dropFirst()),
            [
                Archive.trackA.localHeaderOffset
                    ..< Archive.trackA.localHeaderOffset + LCPArchiveTrackLengthResolver.localHeaderReadLength,
                Archive.trackA.dataOffset + Archive.trackA.storedLength - 32
                    ..< Archive.trackA.dataOffset + Archive.trackA.storedLength,
                Archive.trackB.localHeaderOffset
                    ..< Archive.trackB.localHeaderOffset + LCPArchiveTrackLengthResolver.localHeaderReadLength,
                Archive.trackB.dataOffset + Archive.trackB.storedLength - 32
                    ..< Archive.trackB.dataOffset + Archive.trackB.storedLength
            ],
            "nothing between an entry's header and its final two AES blocks is worth fetching"
        )
    }

    /// The count goes straight into the device log, so it must be what was
    /// reported, not what was asked for.
    func testResolveLengths_returnsTheNumberItReported() async {
        let archive = Archive.make()
        let reported = Reported()

        let summary = await LCPArchiveTrackLengthResolver(
            archiveLength: archive.declaredLength,
            readRange: { await archive.read($0) },
            decipher: { $0 }
        )
        .resolveLengths(forHrefs: ["track-a.mp3", "manifest.json", "track-b.mp3"]) { href, length in
            reported.record(href, length)
        }

        XCTAssertEqual(
            summary.resolved, 2,
            "three tracks were asked for and the deflated one resolved to nothing"
        )
        XCTAssertEqual(
            summary.resolved, reported.values.count,
            "the count must match what the caller was told"
        )
    }

    /// The reported cost is the resolution's own. Measured on device against
    /// the shared archive client, the figure was 41 MB, nearly all of it
    /// playback's read-ahead running at the same time.
    func testResolveLengths_countsOnlyItsOwnReads() async {
        let archive = Archive.make()
        let reported = Reported()

        let summary = await LCPArchiveTrackLengthResolver(
            archiveLength: archive.declaredLength,
            readRange: { await archive.read($0) },
            decipher: { $0 }
        )
        .resolveLengths(forHrefs: ["track-a.mp3", "track-b.mp3"]) { href, length in
            reported.record(href, length)
        }

        XCTAssertEqual(
            summary.requests, archive.reads.count,
            "every read the resolution issued must be counted, and no other"
        )
        XCTAssertEqual(
            summary.requests, 5,
            "the tail, then a header and a ciphertext tail for each of the two tracks"
        )
        XCTAssertEqual(
            summary.bytes,
            Int(Archive.length) + 2 * Int(LCPArchiveTrackLengthResolver.localHeaderReadLength) + 64,
            "the bytes are what came back: the whole short archive as its tail, two headers, two 32-byte tails"
        )
    }

    /// The archive is 715 MB in production; the tail read has to be bounded to
    /// its end, or this reads the whole file to find 4,647 bytes of directory.
    func testResolveLengths_readsOnlyTheTailOfALargeArchive() async {
        let archive = Archive.make()
        archive.declaredLength = 749_772_033

        _ = await resolve(["track-a.mp3"], in: archive)

        XCTAssertEqual(
            archive.reads.first,
            749_772_033 - LCPArchiveTrackLengthResolver.tailReadLength ..< 749_772_033,
            "the central directory is at the end, and Readium's own open leaves these bytes local"
        )
    }

    /// A deflated entry's stored bytes are not its ciphertext, so this
    /// arithmetic does not apply to it and must not be attempted.
    func testResolveLengths_skipsADeflatedEntry() async {
        let archive = Archive.make()

        let reported = await resolve(["manifest.json"], in: archive)

        XCTAssertEqual(reported, [:], "a deflated entry has no derivable plaintext length")
        XCTAssertEqual(
            archive.reads.count, 1,
            "the tail is read to find out it is deflated; nothing else is fetched"
        )
    }

    /// Every length already known is the steady state after the first play, and
    /// it must cost no request at all.
    func testResolveLengths_withNoTracksToResolve_readsNothing() async {
        let archive = Archive.make()

        let reported = await resolve([], in: archive)

        XCTAssertEqual(reported, [:])
        XCTAssertEqual(archive.reads, [], "an empty list must not even read the tail")
    }

    /// An archive of no length names no bytes to read, and a read of an empty
    /// range costs a request that can only fail.
    func testResolveLengths_withNoArchiveLength_readsNothing() async {
        let archive = Archive.make()
        archive.declaredLength = 0

        let reported = await resolve(["track-a.mp3"], in: archive)

        XCTAssertEqual(reported, [:])
        XCTAssertEqual(archive.reads, [], "there is no tail to read in an archive of no length")
    }

    /// The last byte of the archive is inside it. Refusing an entry that ends
    /// there would leave that track on the probe for the life of the book.
    func testResolveLengths_acceptsAnEntryThatEndsAtTheArchivesLastByte() async {
        let archive = Archive.make()

        let reported = await resolve(["track-exact.mp3"], in: archive)

        XCTAssertEqual(
            reported, ["track-exact.mp3": Archive.exactFit.plaintextLength],
            "a ciphertext ending on the final byte fits; only one running past it does not"
        )
    }

    /// The other side of the same bound: an entry whose header begins where the
    /// archive ends has nothing to read, and must not be asked for.
    func testResolveLengths_whenAnEntrysHeaderStartsAtTheArchivesEnd_readsNothingForIt() async {
        let archive = Archive.make()

        let reported = await resolve(["track-at-end.mp3"], in: archive)

        XCTAssertEqual(reported, [:])
        XCTAssertEqual(
            archive.reads.count, 1,
            "the tail is read to find the entry; the entry itself costs no request"
        )
    }

    // MARK: - When the archive does not answer

    func testResolveLengths_whenTheTailDoesNotParse_reportsNothing() async {
        let archive = Archive.make()
        archive.bytes = Data(repeating: 0x41, count: Int(Archive.length))

        let reported = await resolve(["track-a.mp3"], in: archive)

        XCTAssertEqual(
            reported, [:],
            "without an end-of-central-directory record there is no directory to believe"
        )
    }

    func testResolveLengths_whenATrackReadFails_stillResolvesTheNext() async {
        let archive = Archive.make()
        archive.failReadsAt = Archive.trackB.localHeaderOffset

        let reported = await resolve(["track-b.mp3", "track-a.mp3"], in: archive)

        XCTAssertEqual(
            reported, ["track-a.mp3": Archive.trackA.plaintextLength],
            "one unreadable header must not cost the rest of the book its lengths"
        )
    }

    func testResolveLengths_whenTheLicenceCannotDecipher_reportsNothing() async {
        let archive = Archive.make()

        let reported = await resolve(["track-a.mp3"], in: archive, decipher: { _ in nil })

        XCTAssertEqual(
            reported, [:],
            "a length guessed without deciphering the padding would truncate or over-read the chapter"
        )
    }

    /// A directory that names more bytes than the archive holds is either a
    /// corrupt read or another archive's directory. Reading on that basis is
    /// how one book's bytes end up interpreted at another's offsets.
    func testResolveLengths_whenAnEntryRunsPastTheArchive_readsNothingBeyondIt() async {
        let archive = Archive.make()

        let reported = await resolve(["track-overrun.mp3"], in: archive)

        XCTAssertEqual(reported, [:], "an entry that cannot fit is not this archive's entry")
        XCTAssertTrue(
            archive.reads.allSatisfy { $0.upperBound <= Archive.length },
            "no read may run past the length the archive reported"
        )
    }

    // MARK: - Matching a reading-order href to an entry

    /// The player keys its cache on the reading-order href, and a manifest may
    /// spell that href rooted or percent-encoded while the ZIP entry carries
    /// the raw name. A miss here leaves the track on the slow probe with no
    /// diagnostic.
    func testResolveLengths_matchesARootedAndPercentEncodedHref() async {
        let archive = Archive.make()

        let reported = await resolve(["/track%20c.mp3"], in: archive)

        XCTAssertEqual(
            reported, ["/track%20c.mp3": Archive.trackC.plaintextLength],
            "the length must be reported under the href the player will ask with"
        )
    }

    func testResolveLengths_doesNotAnswerForAnHrefTheArchiveDoesNotHold() async {
        let archive = Archive.make()

        let reported = await resolve(["track-z.mp3"], in: archive)

        XCTAssertEqual(
            reported, [:],
            "answering with another entry's length decrypts to the wrong end of the track"
        )
    }

    // MARK: - Cancellation

    /// The resolution outlives the open it starts from, so a patron who closes
    /// the book must not leave 49 tracks' worth of requests running. One read
    /// at a time, so the boundary is the next track.
    func testResolveLengths_whenCancelled_stopsBeforeTheNextTrack() async {
        let archive = Archive.make()
        let box = TaskBox()
        archive.onRead = { range in
            if range.lowerBound == Archive.trackB.localHeaderOffset { box.cancel() }
        }

        let reported = Reported()
        let task = Task {
            _ = await LCPArchiveTrackLengthResolver(
                archiveLength: archive.declaredLength,
                readRange: { await archive.read($0) },
                decipher: { $0 }
            )
            .resolveLengths(
                forHrefs: ["track-b.mp3", "track c.mp3"],
                maxConcurrentReads: 1
            ) { href, length in
                reported.record(href, length)
            }
        }
        box.hold(task)
        await task.value

        XCTAssertEqual(
            reported.values["track-b.mp3"], Archive.trackB.plaintextLength,
            "the track already in flight when the cancellation lands still finishes"
        )
        XCTAssertNil(
            reported.values["track c.mp3"],
            "a cancelled resolution must not keep fetching the tracks after it"
        )
        XCTAssertTrue(
            archive.reads.allSatisfy { $0.lowerBound < Archive.trackC.localHeaderOffset },
            "no read may be issued for a track reached after the cancellation"
        )
    }

    /// The same contract with reads overlapping: the tracks already in flight
    /// finish, and no track behind them is started.
    func testResolveLengths_whenCancelledWithReadsOverlapping_startsNoFurtherTrack() async {
        let archive = Archive.make()
        let box = TaskBox()
        archive.onRead = { range in
            if range.lowerBound == Archive.trackB.localHeaderOffset { box.cancel() }
        }

        let reported = Reported()
        let task = Task {
            _ = await LCPArchiveTrackLengthResolver(
                archiveLength: archive.declaredLength,
                readRange: { await archive.read($0) },
                decipher: { $0 }
            )
            .resolveLengths(
                forHrefs: ["track-a.mp3", "track-b.mp3", "track c.mp3"],
                maxConcurrentReads: 2
            ) { href, length in
                reported.record(href, length)
            }
        }
        box.hold(task)
        await task.value

        XCTAssertNil(reported.values["track c.mp3"], "the third track was never started")
        XCTAssertTrue(
            archive.reads.allSatisfy { $0.lowerBound < Archive.trackC.localHeaderOffset },
            "no read may be issued for a track the cancellation never admitted"
        )
    }

    // MARK: - Driving the resolver

    // MARK: - Which track first, and how many at a time

    /// A patron who resumes in the middle of a book needs that chapter's
    /// length first. Reading order would reach it last, and the chapter pays
    /// Readium's megabyte probe in the meantime.
    func testResolveLengths_readsTheTrackAChapterLoadAskedForBeforeReadingOrder() async {
        let archive = Archive.make()

        let reported = await resolve(
            ["track-a.mp3", "track-b.mp3", "track c.mp3"],
            in: archive,
            demanding: "track c.mp3"
        )

        XCTAssertEqual(reported.count, 3, "every track is still resolved")
        XCTAssertEqual(
            archive.reads.dropFirst().first,
            Archive.trackC.localHeaderOffset
                ..< Archive.trackC.localHeaderOffset + LCPArchiveTrackLengthResolver.localHeaderReadLength,
            "after the tail, the demanded track's header is the first thing read"
        )
    }

    /// With nothing demanded the order is the order given, which is reading
    /// order: the chapters a patron reaches first are known first.
    func testResolveLengths_withNothingDemanded_keepsTheOrderItWasGiven() async {
        let archive = Archive.make()

        _ = await resolve(["track-a.mp3", "track-b.mp3", "track c.mp3"], in: archive)

        XCTAssertEqual(
            archive.reads.dropFirst().first,
            Archive.trackA.localHeaderOffset
                ..< Archive.trackA.localHeaderOffset + LCPArchiveTrackLengthResolver.localHeaderReadLength
        )
    }

    /// Measured on device: 28 tracks took 47.0s for 70,016 bytes, so the fill
    /// is bound by round trips rather than bytes, and a chapter change during
    /// it still pays the probe. Reads overlap to shorten that window.
    func testResolveLengths_withSeveralReadsAllowed_keepsMoreThanOneInFlight() async {
        let archive = Archive.make()
        let depth = ReadDepth()
        archive.onReadAsync = { _ in
            depth.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            depth.leave()
        }

        let reported = await resolve(
            ["track-a.mp3", "track-b.mp3", "track c.mp3"],
            in: archive,
            maxConcurrentReads: 3
        )

        XCTAssertEqual(reported.count, 3)
        XCTAssertGreaterThan(depth.highest, 1, "reads for different tracks must overlap")
        XCTAssertLessThanOrEqual(depth.highest, 3, "and no more than the bound allows")
    }

    /// The bound is a bound: at one read at a time nothing overlaps, so a
    /// patron's chapter is never competing with three of these.
    func testResolveLengths_withOneReadAllowed_runsThemOneAtATime() async {
        let archive = Archive.make()
        let depth = ReadDepth()
        archive.onReadAsync = { _ in
            depth.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            depth.leave()
        }

        let reported = await resolve(
            ["track-a.mp3", "track-b.mp3", "track c.mp3"],
            in: archive,
            maxConcurrentReads: 1
        )

        XCTAssertEqual(reported.count, 3)
        XCTAssertEqual(depth.highest, 1)
    }

    /// Counts how many reads are open at once.
    private final class ReadDepth: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var maximum = 0

        var highest: Int { lock.withLock { maximum } }

        func enter() {
            lock.withLock {
                current += 1
                maximum = max(maximum, current)
            }
        }

        func leave() { lock.withLock { current -= 1 } }
    }

    private func resolve(
        _ hrefs: [String],
        in archive: LCPArchiveReadDouble,
        maxConcurrentReads: Int = 1,
        demanding demanded: String? = nil,
        decipher: @escaping LCPArchiveTrackLengthResolver.Decipher = { $0 }
    ) async -> [String: UInt64] {
        let reported = Reported()
        await LCPArchiveTrackLengthResolver(
            archiveLength: archive.declaredLength,
            readRange: { await archive.read($0) },
            decipher: decipher
        )
        .resolveLengths(
            forHrefs: hrefs,
            maxConcurrentReads: maxConcurrentReads,
            nextDemanded: { demanded }
        ) { href, length in
            reported.record(href, length)
        }
        return reported.values
    }

    /// Collects the reported lengths. A class so the resolver's `@Sendable`
    /// callback can write to it from the task it runs on.
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: UInt64] = [:]

        func record(_ href: String, _ length: UInt64) {
            lock.withLock { storage[href] = length }
        }

        var values: [String: UInt64] {
            lock.withLock { storage }
        }
    }

    /// Holds the task under test so a read can cancel the work it is part of.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func hold(_ task: Task<Void, Never>) {
            lock.withLock {
                self.task = task
                if cancelled { task.cancel() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                task?.cancel()
            }
        }
    }
}

#endif
